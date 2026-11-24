import SwiftUI

@main
struct TingshuRootApp: App {
    init() {
        // 最早时机装崩溃钩子：未捕获 NSException 会在进程退出前落盘
        CrashLog.installUncaughtHandler()
        CrashLog.write("BOOT", "app start v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        // 进后台/退出时把缓冲日志刷盘（平时不做 fsync 省开销）
        CrashLog.installFlushObservers()
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
            // 顺序要紧：自绘分支必须放在「iOS 26 配件」分支之前。
            // 它只是普通 TabView + 系统修饰符，任何部署目标都不会触发可用性检查；
            // 而 26 配件分支虽然被 #available 隔开，SwiftUI 的 custom accessory API
            // 不被它保护 —— 用低版本 SDK（Xcode < 26）编译时照样报 unknown modifier。
            // 因此把 26 分支挪到最后，并用 #if compiler(>=6.2) 整段包住
            // （见 systemTabsWithAccessory），旧工具链编译时那段代码根本不进 AST。
            if useCustomDock {
                customDockLayout
#if compiler(>=6.2)
            } else if #available(iOS 26.0, *) {
                systemTabsWithAccessory
#endif
            } else {
                systemTabsWithSafeAreaInset
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
        }
        .onDisappear { CrashLog.write("UI", "root disappear tab=\(tab)") }
    }

    // MARK: - ① 自绘 dock（iPhone 竖屏）

    private var customDockLayout: some View {
        ZStack(alignment: .bottom) {
            tabContents
                // 隐藏系统 TabBar（逐个 Tab 的内容都要挂，所以放在 TabView 外层统一施加）
                .toolbar(.hidden, for: .tabBar)
                // 自绘条自己占位：系统已经不知道有什么东西挡在底部了
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    BottomDock(selection: $tab)
                }

            // 有内容时，迷你条浮在 dock 之上（dock 已用 safeAreaInset 占位，
            // 这里只往上叠一层，不再加 padding）
            VStack(spacing: 6) {
                MiniPlayerBar()
                    .padding(.horizontal, Layout.miniBarSideMargin)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusBar))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.radiusBar)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.22), value: player.nowPlaying.isEmpty)
            .padding(.bottom, Layout.dockHeight + 16)
        }
    }

    // MARK: - ② iOS 26 系统 TabView + 底部配件

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var systemTabsWithAccessory: some View {
        tabContents
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
        tabContents
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
            .animation(.easeInOut(duration: 0.22), value: player.nowPlaying.isEmpty)
    }

    // MARK: - 内容（三档共用，Tab 结构一处维护）

    private var tabContents: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            CategoryView()
                .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            ShelfView()
                // 书架是「我的内容」，不是「喜欢」
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
                .tag(2)

            MineView()
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(3)
        }
    }
}
