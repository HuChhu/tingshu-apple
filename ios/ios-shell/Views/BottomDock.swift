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
    /// 旋转时钟：独立 ObservableObject，避免 TimelineView 每帧改 @State 重建整棵 dock
    @StateObject private var vinyl = CoverRotationClock()

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
        // 【v1.4.4 修重叠】不再用常量推算总高度：
        //   旧写法外层 `.frame(height: dockHeight + 16 + miniBarHeight + 8)`，
        //   而迷你条内部有自己的内边距、dockBody 也有 padding —— 三处各算各的，
        //   常量之和 ≠ 实际渲染高度，于是两段叠在一起（用户截图蓝圈）。
        //   现在 VStack 的 spacing 是「迷你条底 → dock 顶」的唯一空隙来源，
        //   两段都由各自内在尺寸撑开：迷你条底 + 4 == dock 顶，恒成立。
        GeometryReader { geo in
            VStack(spacing: Self.miniBarGapToDock) {
                if hasMiniPlayer {
                    MiniPlayerBar()
                        // 材质连续：与 dock 用同一种 .ultraThinMaterial。
                        // 迷你条自身不带背景（系统配件模式下由系统提供），
                        // 在这里补一层，视觉上才像一块（用户图 3）。
                        .background(
                            RoundedRectangle(cornerRadius: Layout.radiusBar, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                        .padding(.horizontal, Layout.miniBarSideMargin)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // dock 自己给出实际高度，不再由外层猜 56 + 16。
                dockBody(width: min(geo.size.width, 560))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: geo.size.width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.easeInOut(duration: 0.22), value: hasMiniPlayer)
        .accessibilityElement(children: .contain)
        .onAppear { CrashLog.write("UI", "dock appear") }
    }

    /// 迷你条与 dock 之间的间隙：4pt。
    /// 两块面板各自自带内边距，外部只留这 4pt，观感上是一条均匀细缝而不是大空洞。
    private static let miniBarGapToDock: CGFloat = 4

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
        // 横向只算一次：内容宽 = 屏宽 - 左右各 10pt 外边距 - 胶囊内左右各 8pt。
        // 之前先 frame 到「屏宽-20」再加 8pt padding 再套 10pt padding，
        // 三者叠加让胶囊比屏宽多出 16pt，两侧导航键几乎贴边（用户截图就是这个）。
        .frame(width: max(0, width - Layout.dockSideMargin * 2 - 16),
               height: Layout.dockHeight)
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
                    Image(systemName: "music.note").font(.system(size: 20, weight: .semibold))
                }
            case .loading:
                // 加载中：海报不转，外圈套一层不定进度（用户要求「封面不转，外圈显示不定进度」）
                vinylDisc(size: size, spinning: false)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.15)
                    )
            case .playing, .paused:
                // 中间键 = 旋转的专辑海报（用户图 5）。
                // 播放中按倍速转；暂停停在当前角度（Clock 内部累加，不用 repeatForever）。
                vinylDisc(size: size, spinning: state == .playing)
                // 外圈进度环：描边画在圆外 4pt，不占用内部图标空间
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Color.accentColor.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 8, height: size + 8)
                    .allowsHitTesting(false)
            case .failed:
                vinylDisc(size: size, spinning: false, dimmed: true)
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

    /// 唱片式海报键：圆形封面 + 3pt 白边 + 外圈进度环。
    /// 旋转由 TimelineView(.animation) + CoverRotationClock 驱动（见文件末尾）：
    /// 每帧读角度，**不写 @State**，所以不会触发整棵 dock 重建。
    private func vinylDisc(size: CGFloat, spinning: Bool, dimmed: Bool = false) -> some View {
        let coverSide = max(0, size - 6)      // 3pt 白边左右各一
        return ZStack {
            // 底：黑胶盘面（封面加载不出来时也是「一张唱片」而不是空圆）
            Circle().fill(Color.black.opacity(dimmed ? 0.55 : 0.85))

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { ctx in
                AsyncImage(url: URL(string: player.currentCoverUrl)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        ZStack {
                            LinearGradient(colors: [Color.accentColor, Color.black],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note")
                                .font(.system(size: coverSide * 0.4))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    @unknown default:
                        Color.black
                    }
                }
                .frame(width: coverSide, height: coverSide)
                .clipShape(Circle())
                // 中心轴：唱片中心的小黑圆，强化「在转」的观感（喜马拉雅同款唱片感）
                .overlay(alignment: .center) {
                    Circle()
                        .fill(Color.black)
                        .frame(width: coverSide * 0.16, height: coverSide * 0.16)
                }
                .rotationEffect(.degrees(vinyl.angle(at: ctx.date)))
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(Circle())

            // 3pt 白描边 + 外圈进度环
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size + 5, height: size + 5)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)          // 失败：封面变灰
        .opacity(dimmed ? 0.65 : 1)
        // 把最新状态推给时钟：倍速变化只改角速度，不重置角度。
        // 三个入口都挂：body 求值（首帧）、签名变化（倍速/曲目/状态）、出现兜底。
        .onChange(of: spinSignature) { _, _ in pushSpinState() }
        .onAppear { pushSpinState() }
        .task(id: spinSignature) { pushSpinState() }
    }

    /// 影响旋转的输入签名（播放态 + 倍速 + 曲目）。
    private var spinSignature: String {
        let s = state
        let playing = (s == .playing)
        return "\(playing)-\(player.currentSpeed)-\(player.currentBookUrl)-\(player.nowPlaying)"
    }

    private func pushSpinState() {
        vinyl.sync(playing: state == .playing,
                   rate: player.currentSpeed,
                   trackKey: player.currentBookUrl + "#" + player.nowPlaying)
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
            withAnimation(.easeOut(duration: 0.18)) { showEmptyHint = true }
            CrashLog.write("UI", "dock play tap with no content")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeIn(duration: 0.2)) { showEmptyHint = false }
            }
            return
        }
        // 中间键就是播放/暂停键 —— 迷你条里那个已经删掉了，这里成了唯一入口。
        // 想进播放页点迷你条；长按这个键也能进（见 onLongPressGesture）。
        if player.state == .playing {
            player.pause()
        } else {
            player.resume()
        }
    }
}

// MARK: - 旋转时钟（中间键的海报转圈）

/// 累加角度时钟。
///
/// 为什么不能用 `withAnimation(.linear.repeatForever(autoreverses: false))`：
/// 那是「一次性动画」——暂停 = 移除动画，恢复 = 从头再播一遍，角度必然跳回 0。
/// 用户明确要求「暂停停在当前角度，恢复从该角度继续」，所以只能自己累加。
///
/// 做法：
///   · 观察 Player 的播放状态/倍速/曲目，状态变化时把「之前的累计角度」结算进
///     `baseAngle`，然后换新的角速度继续跑；
///   · 视图侧用 `TimelineView(.animation)` 每帧取 `angle(at:)`，没有任何 @State 变更，
///     所以不会因为旋转触发 body 重建（这是它必须独立成 ObservableObject 的原因）。
@MainActor
final class CoverRotationClock: ObservableObject {

    /// 基准：1.0 倍速下 20 秒转一圈 → 每秒 18°
    static let degreesPerSecondAt1x: Double = 360.0 / 20.0

    /// 上一次结算的时刻（也是当前分段的起点）
    private var segmentStart = Date()
    /// 已经走完的角度（跨倍速/暂停结算后的累计值）
    private var baseAngle: Double = 0
    /// 当前角速度（度/秒）；0 = 不转
    private var speed: Double = 0



    /// 由 BottomDock 在 body 求值时调用（幂等：参数没变就什么都不做）。
    func sync(playing: Bool, rate: Double, trackKey: String) {
        // 换曲：角度归零（新唱片从正面开始）
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            baseAngle = 0
            segmentStart = Date()
        }
        let target = playing ? Self.degreesPerSecondAt1x * (rate.isFinite ? max(0.25, rate) : 1) : 0
        settle(at: Date())
        if target != speed {
            // 只改角速度，绝不重置 baseAngle —— 倍速变化时角度必须连续
            speed = target
        }
    }

    /// 当前角度（度）。TimelineView 每帧调用。
    func angle(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(segmentStart))
        return (baseAngle + speed * elapsed).truncatingRemainder(dividingBy: 360)
    }

    /// 把「已走过的角度」写进 baseAngle，并把新分段的起点设为 now。
    private func settle(at now: Date) {
        let elapsed = max(0, now.timeIntervalSince(segmentStart))
        baseAngle = (baseAngle + speed * elapsed).truncatingRemainder(dividingBy: 360)
        segmentStart = now
    }

    private var lastTrackKey: String = ""
}
