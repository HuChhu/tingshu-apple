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
    /// 封面只加载一次，Timeline 每帧复用它 —— 避免逐帧重建 AsyncImage 造成闪变
    @State private var coverImage: Image?

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
        // 【v1.4.6 固定占位】迷你条用 ZStack 淡入淡出，**永远占位**：
        // 之前用 if 包着，迷你条一出现 safeAreaInset 就从 72 长到 138，
        // 整块胶囊和页面内容跟着上跳 66pt，观感很脏。
        // 现在高度恒定 = 迷你条(60) + gap(6) + 胶囊区(64) + 底(8)，显隐只改透明度。
        ZStack(alignment: .top) {
            // 迷你条：**固定占位**，显隐只改透明度。
            // 槽位高度必须与 MiniPlayerBar 的真实高度相等（60），否则
            // 底部 safeAreaInset 会在迷你条出现时整体长高 66pt，内容区跳一下。
            MiniPlayerBar()
                .frame(height: Self.miniSlotHeight)
                // 关键：接受 ZStack 给的高度、只在其中顶部对齐。
                // 不加这行，ZStack 高度 = max(迷你条 60, dock 区 72) = 72 才没被顶下去 ——
                // 是「72 恰好比 60 大」的数值巧合。加了之后任何调参都免疫。
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, Layout.miniBarSideMargin)
                .background(
                    RoundedRectangle(cornerRadius: Layout.radiusBar, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.radiusBar, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .opacity(hasMiniPlayer ? 1 : 0)
                // 幽灵热区防线：透明度 0 的条不许吃触摸（否则迷你条隐藏时，
                // dock 上方 60pt 是一片「看不见但能点」的区域）。
                .allowsHitTesting(hasMiniPlayer)
                .accessibilityHidden(!hasMiniPlayer)
                .animation(.easeInOut(duration: 0.2), value: hasMiniPlayer)

            VStack(spacing: 0) {
                // 迷你条槽位：有内容时占 60+6，没内容时收成 0 —— dock 贴着底部不动，
                // 页面内容只在迷你条出现/消失时让出/收回这 66pt（带 0.2s 动画，不是瞬跳）。
                // 上一版为了「不跳」把它固定成永久 66，结果「我的」这种长列表底部永远空一条，
                // 用户会以为界面漏了一块。
                Color.clear
                    .frame(height: hasMiniPlayer
                           ? Self.miniSlotHeight + Self.gapBetweenMiniBarAndDock
                           : 0)
                dockCapsule()
                    .padding(.horizontal, Layout.dockSideMargin)
                    .padding(.bottom, 8)
            }
        }
        // 封面下载挂在**稳定的最外层**，不在 vinylDisc 内部：
        // vinylDisc 的形态随状态（空/加载/播放/暂停/失败）变化，视图身份一变 task 就被取消重跑，
        // 表现为盘面每换一次状态就重新下一遍图 —— 这也是「盘面闪变」的一条来源。
        .task(id: player.currentCoverUrl) { await loadCover() }
        .animation(.easeInOut(duration: 0.2), value: hasMiniPlayer)
        .accessibilityElement(children: .contain)
        .onAppear { CrashLog.write("UI", "dock appear") }
    }

    /// 中间键轻微凸出条面的高度（58 直径 + 12 热区 = 70，条面 56，露 8）。
    private static let playKeyOverhang: CGFloat = 8
    /// 迷你条的固定占位高度。
    /// **必须等于 MiniPlayerBar.barHeight** —— 两处若各算各的，
    /// 底部 safeAreaInset 高度会在迷你条出现时变化，页面整体跳 66pt。
    private static let miniSlotHeight: CGFloat = MiniPlayerBar.barHeight
    /// 迷你条底边到胶囊顶边的可见空隙（不含播放键凸出的那 8pt）。
    private static let gapBetweenMiniBarAndDock: CGFloat = 6

    /// 唯一一层玻璃：胶囊本体。中间键画在它上面，凸出部分露在胶囊上沿之外。
    private func dockCapsule() -> some View {
        ZStack(alignment: .top) {
            // 胶囊高度就是条面高度，用 padding(.top, 8) 把它下推 8pt 给播放键让位。
            // 之前写成 .offset(y: 8)：offset 只移动绘制、不改布局，胶囊底边会溢出
            // ZStack 底边 8pt，把外层留的空白画满 —— 就是用户截图里「dock 下面还露一条玻璃」。
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .frame(height: Layout.dockHeight)
                .padding(.top, Self.playKeyOverhang)

            HStack(spacing: 0) {
                ForEach(Self.leftTabs, id: \.id) { tabButton($0) }
                playKey(size: Layout.dockPlayKey)
                ForEach(Self.rightTabs, id: \.id) { tabButton($0) }
            }
            // 导航键与胶囊一起下移 8pt，保持与条面垂直居中
            .padding(.top, Self.playKeyOverhang)
            .frame(height: Layout.dockHeight)

            if showEmptyHint {
                Text("先去选一本")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.regularMaterial))
                    .transition(.opacity)
            }
        }
        .frame(height: Layout.dockHeight + Self.playKeyOverhang)
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
        // 【v1.4.6】用 Button 代替手搓的 onLongPressGesture：
        // 之前手指按住后横滑超过 14pt，SwiftUI 判定手势失败也会回调 pressing(false)，
        // 代码把它当「抬起」执行动作 —— 从中间键滑向旁边 Tab 的常见轨迹必然误触。
        // Button 的取消语义由系统保证：滑出范围松手不触发 action。
        Button {
            handlePlayTap()
        } label: {
            keyVisual(size: size)
        }
        .buttonStyle(PlayKeyButtonStyle())
        .accessibilityLabel(hasContent ? "打开播放页" : "播放")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hasContent ? "进入正在播放的专辑" : "先去选一本")
    }

    /// 视觉本身与手势解耦：ButtonStyle 用 isPressed 驱动缩放。
    @ViewBuilder
    private func keyVisual(size: CGFloat) -> some View {
        ZStack {
            switch state {
            case .empty:
                playCircle(size: size, fill: Color.secondary.opacity(0.18),
                           foreground: Color.secondary) {
                    Image(systemName: "music.note").font(.system(size: 20, weight: .semibold))
                }
            case .loading:
                vinylDisc(size: size, spinning: false)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.1)
                    )
            case .playing, .paused:
                vinylDisc(size: size, spinning: state == .playing)
            case .failed:
                vinylDisc(size: size, spinning: false, dimmed: true)
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                    .offset(x: size / 2 - 4, y: -size / 2 + 4)
                    .allowsHitTesting(false)
            }
        }
        // 中间键热区比视觉大一圈，但不外扩到相邻 Tab（width = size + 4）
        .frame(width: size + 4, height: Layout.dockHeight + Self.playKeyOverhang)
        .contentShape(Rectangle())
    }

    /// 按下缩放。整组一起缩（盘面 + 描边 + 进度环），避免只缩盘面时出现双环错觉。
    private struct PlayKeyButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// 唱片式海报键：圆形封面 + 3pt 白边 + 外圈进度环。
    /// 旋转由 TimelineView(.animation) + CoverRotationClock 驱动（见文件末尾）：
    /// 每帧读角度，**不写 @State**，所以不会触发整棵 dock 重建。
    private func vinylDisc(size: CGFloat, spinning: Bool, dimmed: Bool = false) -> some View {
        let coverSide = max(0, size - 6)      // 3pt 白边左右各一
        return ZStack {
            Circle().fill(Color.black.opacity(dimmed ? 0.55 : 0.85))

            // 【v1.4.6 真修「重影」】
            // 上一版把 coverFace 写在 TimelineView 闭包里 —— 名字叫「外面加载一次」，
            // 实际每帧仍在闭包里重建 AsyncImage。录屏帧分析显示盘面每 0.7~1.2 秒
            // 突然亮到暗再恢复，就是封面被反复重建。
            // 现在改成「Image 只在外面加载一次 → 存进 @State → Timeline 只做 rotationEffect」。
            if let img = coverImage {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { ctx in
                    img
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: coverSide, height: coverSide)
                        .clipShape(Circle())
                        .overlay(alignment: .center) {
                            Circle()
                                .fill(Color.black)
                                .frame(width: coverSide * 0.16, height: coverSide * 0.16)
                        }
                        .rotationEffect(.degrees(vinyl.angle(at: ctx.date)))
                }
                .frame(width: coverSide, height: coverSide)
            } else {
                coverPlaceholder(side: coverSide)
                    .frame(width: coverSide, height: coverSide)
                    .clipShape(Circle())
            }

            // 3pt 白描边 + 外圈进度环（不参与旋转）
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
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.65 : 1)
        .onChange(of: spinSignature) { _, _ in pushSpinState() }
        .onAppear { pushSpinState() }
        .task(id: spinSignature) { pushSpinState() }
    }

    /// 封面只在这里下载一次，下载完存成 Image；Timeline 每帧只改角度。
    private func loadCover() async {
        let want = player.currentCoverUrl
        // 换书：立刻清掉上一本的封面，不要「先显示旧书、下载完再突变」
        coverImage = nil
        guard !want.isEmpty, let u = URL(string: want) else { return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode < 400 else { return }
            // 下载期间用户可能又换了一本：只接受当前 URL 的结果
            guard want == player.currentCoverUrl else { return }
            // 预先按目标像素解码，交给 Timeline 的只是一张已解码小图
            let side = max(1, Layout.dockPlayKey)
            guard let img = downscale(data: data, side: side) else { return }
            coverImage = img
        } catch {
            // 失败就保持占位，不抛
        }
    }

    /// 把封面解码并缩到 dock 键尺寸，避免每帧在 Timeline 里对原图做 fill 布局。
    private func downscale(data: Data, side: CGFloat) -> Image? {
        guard let src = UIImage(data: data) else { return nil }
        let target = CGSize(width: side * 3, height: side * 3)   // 3x 供 Retina
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: fmt)
        let out = renderer.image { _ in
            let scale = max(target.width / src.size.width, target.height / src.size.height)
            let w = src.size.width * scale
            let h = src.size.height * scale
            src.draw(in: CGRect(x: (target.width - w) / 2, y: (target.height - h) / 2,
                                width: w, height: h))
        }
        return Image(uiImage: out)
    }

    private func coverPlaceholder(side: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor, Color.black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: side * 0.4))
                .foregroundStyle(.white.opacity(0.8))
        }
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
        // 【v1.4.5 回到原设计】用户原话："我不是说让你做成点一下开、点一下关，
        // 而是说可以直接进入播放页面……开始做得挺好的，我只是让你增加了一点功能。"
        // 所以中间键 = 进播放页（和最初一致）；播放/暂停仍然由播放页里的大按钮负责。
        player.showFullScreen = true
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
