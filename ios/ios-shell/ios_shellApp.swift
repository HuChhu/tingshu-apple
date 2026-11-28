import SwiftUI

@main
struct TingshuRootApp: App {
    init() {
        // 最早时机装崩溃钩子：未捕获 NSException 会在进程退出前落盘
        CrashLog.installUncaughtHandler()
        CrashLog.write("BOOT", "app start v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        // 进后台/退出时把缓冲日志刷盘（平时不做 fsync 省开销）
        CrashLog.installFlushObservers()
        // 【2026-11-26 修「海报要 3-4 秒才出来」】
        // URLSession.shared 的默认 URLCache 内存只有 512KB、磁盘 10MB，
        // 一张封面 200-400KB，翻两屏就被挤掉 —— 每次重建列表都重新下载。
        // 这里换成 64MB 内存 + 512MB 磁盘；配合 Layout.coverURL 的尺寸收敛，
        // 同一张图只会真正下载一次。
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "tingshu-cover-cache"
        )
    }

    var body: some Scene {
        WindowGroup { RootTabView() }
    }
}

/// 根容器：4 个 Tab + 底部播放层。
///
/// 底部栏三档（互斥，见 BottomDock.swift 顶部注释）：
///   ① 自绘 dock（iPhone 竖屏，要中间大播放键）→ 隐藏系统 TabBar + BottomDock
///   ② iOS 26+ 系统 TabView → tabViewBottomAccessory 挂迷你条
///   ③ iOS 17–25 → .safeAreaInset(edge: .bottom) 挂迷你条
///
/// 三种情况都**不再**手算 TabBar 高度：① 不需要（系统条已隐藏），②③ 由系统让位。
struct RootTabView: View {
    /// 跨页跳转用（搜索失败 → 「用其他源搜」切到分类页；值是 Tab 下标 1）
    @AppStorage("selectedTab") private var tab = 0
    /// 必须订阅 Player，否则 showFullScreen 变化不会驱动 fullScreenCover
    @ObservedObject private var player = Player.shared
    /// iPhone 竖屏 = compact；iPad / 横屏 = regular → 走系统 TabView，不自绘
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 是否自绘底部 dock。判定优先级：
    ///   1. 系统给了 regular（iPad / 横屏）→ 一律不自绘，避免窄条被拉成横跨整屏
    ///   2. nil（某些容器/预览里读不到）→ 当成 compact，保持视觉一致
    ///   3. 用户要求中间播放键 → 自绘
    private var useCustomDock: Bool {
        BottomBarStyle.usesCustomBar(regularWidth: hSizeClass == .regular)
    }

    var body: some View {
        Group {
            // #if 不能插在 if/else 链中间：Swift 在 release 工具链上直接报
            // 「unexpected 右花括号 in conditional compilation block」（实测 CI Xcode 16.x）。
            // 正确做法是让条件编译整个包住一个**完整的**分支，而不是拼接半个 else-if。
            // 低版本 SDK 时 pickSystemTabs() 里的 iOS 26 分支不存在，
            // 26 的 custom accessory API 也就不会进 AST。
            if useCustomDock {
                customDockLayout
            } else {
                systemTabsCompat
            }
        }
        // fullScreenCover 挂在这里，但**只有用户显式动作**才会把它打开：
        // 迷你条 / 底部 dock 播放键 / 首页「继续听」的播放键 / 播放历史行。
        // 切 Tab 不碰 showFullScreen —— 这一层不再有任何「跟着播放状态自己弹」的路径。
        .fullScreenCover(isPresented: Binding(
            get: { player.showFullScreen },
            set: { player.showFullScreen = $0 }
        )) {
            // 全屏页必须自带导航容器：PlayerView 顶层是 GeometryReader + VStack，
            // 它的 navigationTitle / toolbar 只有在 NavigationStack 里才渲染。
            NavigationStack {
                PlayerView()
            }
        }
        .onAppear {
            CrashLog.write("UI", "root appear tab=\(tab) fullscreen=\(player.showFullScreen) dock=\(useCustomDock)")
            // 冷启动恢复「上次在听」的展示状态：否则 Player 的 state 是 .stopped、
            // nowPlaying 是空串，悬浮条永远不出现（用户反馈的「清后台重开就不见了」）。
            player.restoreLastPlaybackIfNeeded()
        }
        .onDisappear { CrashLog.write("UI", "root disappear tab=\(tab)") }
    }

    // MARK: - ① 自绘 dock（iPhone 竖屏）

    private var customDockLayout: some View {
        // 用**参数**告诉 tabContents 藏系统 TabBar，而不是静态变量。
        // 静态变量的坑：本档设成 true 之后没人改回去，用户转到 iPad/横屏（走系统档）时
        // tabContents() 读到的还是 true，系统档的 TabBar 也被一起藏掉，连切 Tab 都没了。
        // 参数随调用点取值，零跨分支状态。
        tabContents(hidesSystemTabBar: true)
            // 【v1.4.8 双栏修法（定稿）】
            //
            // 旧写法把 `.toolbar(.hidden, for: .tabBar)` 挂在 TabView 自己身上 ——
            // Apple 文档：「可见性偏好向上流向最近一个渲染栏的容器」，TabView 就是那个容器，
            // 挂在它身上等于没人接，系统 TabBar 照常渲染 → 底部两套导航栏重叠。
            //
            // 正确位置是每个 Tab 的**内容根**（文档示例写法），这里在 tabContents() 里
            // 对四个 Tab 各挂一次 `.toolbar(hidesSystemTabBar ? .hidden : .automatic, for: .tabBar)`。
            // 【v1.5.6】safeAreaInset 内容不再由 BottomDock 自己 ignoreSafeArea（会被容器裁掉），
            // 改成在 Root 这一层把负 inset 打进去：让 dock 直接吃到屏幕物理底边。
            // spacing: -1 让系统保留的那段 home indicator 不再额外撑高。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 迷你条 + dock 作为一整块占位。
                // 迷你条显隐由 BottomDock 自己处理（固定占位、只改透明度），
                // 这里不能再 if 一次 —— 否则高度算两遍，迷你条会压住导航键。
                BottomDock(selection: $tab)
            }
            // 注意：不要再给自绘档加 `tabBarMinimizeBehavior`。
            // TabBarMinimizeBehavior 在 iOS 26 只有 .automatic / .onScrollDown / .onScrollUp
            // 三个值（Apple 文档），**没有 .never**；而"隐藏"已经由每个 Tab 的
            // `.toolbar(.hidden, for: .tabBar)` 完成，收缩逻辑对已隐藏的条不产生影响。
            // 之前那层 HiddenTabBarOnIOS26 是多余的防御，已删除。
    }

    // MARK: - ② iOS 26 系统 TabView + 底部配件

    /// 系统栏的兼容入口：有 26 SDK 就用 tabViewBottomAccessory（配件由系统托管），
    /// 否则退回 safeAreaInset。整段类型声明用 #if 包住，低版本工具链看不到 26 的 API。
    @ViewBuilder
    private var systemTabsCompat: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            systemTabsWithAccessory
        } else {
            systemTabsWithSafeAreaInset
        }
#else
        systemTabsWithSafeAreaInset
#endif
    }

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var systemTabsWithAccessory: some View {
        tabContents()
            // 配件由 TabView 托管：系统把它贴在悬浮 TabBar 上方，
            // TabBar 收缩时自动内联 —— 不依赖 `_UITabBarPlatterView` 这类私有结构。
            .tabViewBottomAccessory {
                MiniPlayerBar()
                    .padding(.horizontal, Layout.miniBarSideMargin)
            }
            // 滚动时收起 TabBar + 配件（Apple Music 同款），给内容让出高度
            .tabBarMinimizeBehavior(.onScrollDown)
    }
#endif

    // MARK: - ③ iOS 17–25 系统 TabView + safeAreaInset

    private var systemTabsWithSafeAreaInset: some View {
        tabContents()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 只有真出现时才占位：条隐藏时不留下一条空白
                if !player.nowPlaying.isEmpty && player.state != .stopped {
                    MiniPlayerBar()
                        .padding(.horizontal, Layout.miniBarSideMargin)
                        .padding(.bottom, Layout.miniBarGap)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusBar))
                        .overlay(
                            RoundedRectangle(cornerRadius: Layout.radiusBar)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: player.nowPlaying.isEmpty)
    }

    // MARK: - 内容（三档共用，Tab 结构一处维护）

    /// 三档共用的 TabView。
    /// 三档共用的 TabView（只维护一份 Tab 结构）。
    ///
    /// 【v1.4.8 双栏修法】把隐藏偏好挂在每个 Tab 的**内容根**上。
    /// Apple 文档：可见性偏好向上流向最近一个渲染栏的容器（TabView）；
    /// 挂在 TabView 自己身上等于没人接收，这就是之前底部出现两套导航栏的原因。
    /// - Parameter hidesSystemTabBar: 自绘 dock 档位传 true；系统两档不传。
    private func tabContents(hidesSystemTabBar: Bool = false) -> some View {
        TabView(selection: $tab) {
            // 每个 Tab 的内容根各挂一次：TabView 只读当前 Tab 的偏好，
            // 只挂一个的话切走再回来就失效。
            // 只在需要隐藏时挂 —— 显式写 .automatic 会把子页面自己的
            // 「隐藏 tabBar」请求一并顶掉（本项目暂无这种页面，但不留隐患）。
            HomeView()
                .modifier(MaybeHideTabBar(hidden: hidesSystemTabBar))
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            CategoryView()
                .modifier(MaybeHideTabBar(hidden: hidesSystemTabBar))
                .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            ShelfView()
                .modifier(MaybeHideTabBar(hidden: hidesSystemTabBar))
                // 书架是「我的内容」，不是「喜欢」
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
                .tag(2)

            MineView()
                .modifier(MaybeHideTabBar(hidden: hidesSystemTabBar))
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(3)
        }
    }
}

/// 按需隐藏系统 TabBar：挂在**每个 Tab 的内容根**上（唯一起作用的位置）。
/// hidden=false 时原样返回，不留任何 toolbar 偏好，避免顶掉子页面自己的设置。
private struct MaybeHideTabBar: ViewModifier {
    let hidden: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hidden {
            content.toolbar(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}
