import SwiftUI
import UIKit

// MARK: - 底部栏的三种形态（谁来决定用哪个）

/// 底部栏样式判定。三种形态互斥，任一时刻只会渲染其中一种：
///
///   `.systemAccessory` —— iOS 26+：迷你条交给 `tabViewBottomAccessory`，
///       系统把配件贴在悬浮 TabBar 正上方（TabBar 收缩时自动内联），
///       不需要知道 TabBar 多高 —— 这正是 iOS 26 空隙问题的正解。
///   `.systemSafeAreaInset` —— iOS 17–25：`.safeAreaInset(edge: .bottom)`，
///       系统给的 bottom safe area 本来就 = TabBar + Home 指示条。
///   `.customDock` —— 需要"中间大播放键"时自绘：隐藏系统 TabBar，画 4 个导航键 + 中间圆键。
///
/// 自绘只在 `horizontalSizeClass == .compact`（iPhone 竖屏）时启用：
/// iPad / 横屏会切成 `.sidebarAdaptable` 侧栏，自绘 HStack 会横跨整屏变得难看，
/// 那些尺寸下退回系统 TabView（见 `BottomDock.shouldUseSystemTabs`）。
enum BottomBarStyle {

    /// 用户想要中间播放键（本次交付 → true）
    static let wantsCenterPlayKey = true

    /// 系统是否支持 tabViewBottomAccessory（iOS 26.0+）。
    /// 用 stored property 在类型加载时算一次：`#available` 在静态属性里是合法表达式。
    /// 真正的分支仍然在 RootTabView 的 body 里用 `if #available` 写死，
    /// 因为 SwiftUI 的视图构建需要编译器看得见的 unavailable 分支。
    static let systemSupportsBottomAccessory: Bool = {
        if #available(iOS 26.0, *) { return true }
        return false
    }()

    /// 是否自绘 dock（隐藏系统 TabBar）。
    /// 尺寸判定不在这里：`horizontalSizeClass` 只有 View 环境能读，
    /// 由 RootTabView 的 `useCustomDock` 组合（compact && wantsCenterPlayKey）。
    /// 这里只回答"用户要不要中间键"。
    static var wantsCustomDock: Bool { wantsCenterPlayKey }

    /// 当前设备是不是「真会画自绘栏」——尺寸和系统能力一起判。
    /// 和 RootTabView.useCustomDock 必须同源，否则页面留白与底部栏会各算各的：
    /// 栏用系统方案而页面按自绘条加 80pt，底部就多出一大块空白。
    static func usesCustomBar(regularWidth: Bool) -> Bool {
        wantsCenterPlayKey && !regularWidth
    }
}

// MARK: - 自绘底部 dock

/// 自绘底部栏：首页 / 分类 —— 中间播放键 —— 书架 / 我的
///
/// 为什么不直接用 TabView 的 5 个 Tab：
///   iOS 26 SDK 没有"TabBar 中间插自定义按钮"的公开 API。
///   `TabRole` 在 iOS 18 只有 `.search`（会被拎到右侧独立成圆钮，语义是搜索）；
///   `role: .prominent` 要 iOS 27。所以"中间大播放键"只能自绘。
///
/// 为什么内容仍然是 TabView（见 RootTabView）：
///   保留系统容器，`onAppear` / `.task` / 切页转场 / 内存回收都和原来一致；
///   这里只是把系统 TabBar 用 `.toolbar(.hidden, for: .tabBar)` 藏起来，再画一条视觉替身。
struct BottomDock: View {
    @Binding var selection: Int
    @ObservedObject private var player = Player.shared

    /// 无内容时点播放键的提示
    @State private var showEmptyHint = false
    @State private var pressed = false

    /// 左二 + 右二；中间播放键单画
    private static let leftTabs: [(id: Int, title: String, icon: String)] = [
        (0, "首页", "house.fill"),
        (1, "分类", "square.grid.2x2.fill"),
    ]
    private static let rightTabs: [(id: Int, title: String, icon: String)] = [
        (2, "书架", "books.vertical.fill"),
        (3, "我的", "person.fill"),
    ]

    var body: some View {
        // GeometryReader 撑满父级，所以外面必须给固定高度：
        // safeAreaInset 里 dock 占位 = 条高 56 + 上 8 + 下 8（给凸出的播放键与提示留余量）。
        // 不用 safeAreaInset 时这个高度就是内容被顶起来的距离。
        VStack(spacing: 8) {
            // 迷你条放在同一块占位里，而不是叠在 dock 上：
            // 以前用 overlay + 固定偏移画，两段高度各算各的，56pt 完全重叠、盖住导航键。
            if hasMiniPlayer {
                MiniPlayerBar()
                    .padding(.horizontal, Layout.miniBarSideMargin)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.22), value: hasMiniPlayer)
            }
            GeometryReader { geo in
                dockBody(width: min(geo.size.width, 560))
                    .frame(width: min(geo.size.width, 560),
                           height: Layout.dockHeight + 16, alignment: .bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottom)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Layout.dockHeight + 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.dockHeight + 16 + (hasMiniPlayer ? Layout.miniBarHeight + 8 : 0))
        // 不要 clipped()：中间播放键比胶囊高 14pt（含热区），整体裁切会把它切掉一半，
        // 也会把凸出部分的下半边留白一起吃掉。这里靠 GeometryReader 的 frame 已经约束住了，
        // 溢出只发生在 dock 自身 16pt 的预留空间内。
        .accessibilityElement(children: .contain)
        .onAppear { CrashLog.write("UI", "dock appear") }
    }

    /// 中间键直径：390+ 用 58，320~375 收到 52 ——
    /// 4 个导航键 + 播键 + 两侧边距必须塞进 320pt 宽，否则小屏会挤压文字。
    private func keySize(for width: CGFloat) -> CGFloat {
        width < 380 ? 52 : Layout.dockPlayKey
    }

    private func dockBody(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.leftTabs, id: \.id) { t in
                tabButton(t)
            }

            playKey(size: keySize(for: width))

            ForEach(Self.rightTabs, id: \.id) { t in
                tabButton(t)
            }
        }
        // 条面高 56，中间键（58+12=70 含热区）比条面高 —— 不裁剪即可自然凸出，
        // 凸出部分正好落在 dock 外层 +16 的留白里
        .frame(width: max(0, width - Layout.dockSideMargin * 2),
               height: Layout.dockHeight)
        .padding(.horizontal, 8)
        .background(
            // 胶囊底：与 iOS 26 系统 TabBar 同款量级（材质 + 细描边）
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        // 让开底部安全区（Home 指示条）。不加 TabBar 高度：系统 TabBar 已被隐藏。
        // 底部不再自己加 padding：外层是 safeAreaInset(edge: .bottom)，
        // 系统已经把 dock 摆在安全区（Home 指示条）上沿。这里再补 8pt 就是凭空垫高。
        .padding(.horizontal, Layout.dockSideMargin)
        .overlay(alignment: .bottom) {
            if showEmptyHint {
                Text("先去选一本")
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    // dock 在屏幕最底部，提示必须往上弹（负数 y），否则会被裁到屏幕外
                    .offset(y: -(Layout.dockHeight + 18))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    // MARK: 导航键

    private func tabButton(_ t: (id: Int, title: String, icon: String)) -> some View {
        let on = selection == t.id
        return Button {
            guard selection != t.id else { return }
            // 用 withAnimation 而不是直接赋值：TabView(selection:) 的切换交给系统做转场，
            // 我们只负责高亮变化不做额外位移，避免内容"跳一下"
            selection = t.id
        } label: {
            VStack(spacing: 3) {
                Image(systemName: t.icon)
                    .font(.system(size: 17, weight: on ? .semibold : .regular))
                    .symbolVariant(.fill)
                Text(t.title)
                    .font(.system(size: 10, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.dockHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.title)
        // 系统 TabBar 自带选中 trait，自绘必须自己补，否则 VoiceOver 听不出当前页
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 中间播放键

    @ViewBuilder
    private func playKey(size: CGFloat) -> some View {
        ZStack {
            switch state {
            case .empty:
                playCircle(size: size, fill: Color.secondary.opacity(0.18),
                           foreground: Color.secondary) {
                    Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold))
                }
            case .loading:
                playCircle(size: size, fill: Color.accentColor, foreground: .white) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                }
            case .playing:
                playCircle(size: size, fill: Color.accentColor, foreground: .white) {
                    // 播放中显示暂停图标；暂停中显示播放图标（点哪里都是"进播放页"）
                    Image(systemName: "pause.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                // 外圈进度环：描边画在圆外 4pt，不占用内部图标空间
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Color.accentColor.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 8, height: size + 8)
                    .allowsHitTesting(false)
            case .paused:
                playCircle(size: size, fill: Color.accentColor.opacity(0.16), foreground: Color.accentColor) {
                    Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold))
                }
            case .failed:
                playCircle(size: size, fill: Color.red.opacity(0.15), foreground: Color.red) {
                    Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold))
                }
                // 失败红点：右上角，2 个 pt 描边让它从任何底色里跳出来
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                    .offset(x: size / 2 - 4, y: -size / 2 + 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size + 4, height: size + 12)
        .contentShape(Circle())
        // 按下 0.15s 缩放（方案要求），松手回弹
        .scaleEffect(pressed ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.15), value: pressed)
        // 只有一套手势：
        //   onPressingChanged → 按下缩放；perform → 松手（无论长短按）执行动作。
        // 之前同时挂了 onTapGesture + LongPressGesture + onLongPressGesture 三套，
        // 长按会被"点击识别失败"吞掉、pressed 也可能卡住不弹回，这里统一成一套。
        // maximumDistance 12：手指轻微滑动不算取消，避免长按不触发。
        // minimumDuration 不能设大：这个手势同时承担「按下缩放」，
        // 0.12 秒的判定窗口会把快于 120ms 的轻点整个吞掉（用户觉得「点不动」）。
        // 0.05 只用于拿到 pressing 变化，真正的动作在下面两处 perform / onTapGesture。
        .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 12, perform: {
            pressed = false
            handlePlayTap()
        }, onPressingChanged: { down in
            // 长按完成时系统也会回调一次 onPressingChanged(false)，与 perform 的复位重复无害
            pressed = down
        })
        .accessibilityElement()
        // 这个键的动作是「打开播放页」，不是暂停 —— 标签必须说动作，
        // 否则 VoiceOver 上读「暂停」、按下去却弹全屏。
        .accessibilityLabel(hasContent ? "打开播放页" : "播放")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hasContent ? "打开播放页" : "先去选一本")
    }

    private func playCircle<C: View>(size: CGFloat, fill: Color, foreground: Color,
                                     @ViewBuilder content: () -> C) -> some View {
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(content().foregroundStyle(foreground))
    }

    // MARK: 状态

    /// 五种状态 → 五种视觉：空 / 加载中 / 播放中（含进度环）/ 已暂停 / 失败（红点）
    private enum KeyState { case empty, loading, playing, paused, failed }

    private var state: KeyState {
        guard hasContent else { return .empty }
        switch player.state {
        case .playing: return .playing
        case .loading: return .loading
        case .error: return .failed
        case .paused: return .paused
        case .stopped: return .empty
        }
    }

    /// 有当前集才算"有内容"（nowPlaying 是标题，空标题时也不能当成有）
    private var hasMiniPlayer: Bool {
        !player.nowPlaying.isEmpty && player.state != .stopped
    }

    private var hasContent: Bool {
        !player.nowPlaying.isEmpty && player.state != .stopped
    }

    private var progress: Double {
        let p = player.position
        return p.isFinite ? min(1, max(0, p)) : 0
    }

    private func handlePlayTap() {
        guard hasContent else {
            // 无内容：不打开空播放页，给一句就地提示
            withAnimation(.easeOut(duration: 0.18)) { showEmptyHint = true }
            CrashLog.write("UI", "dock play tap with no content")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeIn(duration: 0.2)) { showEmptyHint = false }
            }
            return
        }
        // 有内容：打开全屏播放页（不是暂停/继续 —— 那是迷你条上的按钮的职责，
        // 中间键的语义是"进入播放"）
        player.showFullScreen = true
    }
}
