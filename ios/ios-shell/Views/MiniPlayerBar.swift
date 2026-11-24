import SwiftUI

/// 迷你播放条（系统托管版）。
///
/// 定位原则（v1.4.1 重写）：**壳层不再量 TabBar 高度**。
///   - iOS 26+：作为 `tabViewBottomAccessory` 的配件由 TabView 托管，
///     系统把它贴在悬浮 TabBar 正上方，TabBar 收缩时自动内联；
///   - iOS 17–25：由调用方放进 `.safeAreaInset(edge: .bottom)`，系统自动抬内容区。
///
/// 为什么删掉原来那套 `UIApplication` 扩展：
///   1) `UITabBar.bounds.height` 是容器高度，iOS 26 真正画出来的胶囊是私有视图
///      `_UITabBarPlatterView`，两者不等 —— 这是"迷你条和 TabBar 之间有空隙"的根因；
///   2) 容器高度里已经含底部安全区，外面又加了一次 `safeAreaInsets.bottom`，安全区算两遍；
///   3) `connectedScenes.first` 在分屏/多窗口下不一定拿到当前窗口。
/// 现在这三处全部删除，位置完全由系统决定。
///
/// 注意：本视图**不**再自带胶囊背景与圆角描边 ——
/// iOS 26 的底部配件由系统套一层 Liquid Glass 壳，自带背景会叠成两层玻璃。
struct MiniPlayerBar: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        if shouldShow {
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.nowPlaying)
                        .font(.subheadline).lineLimit(1)
                    Text(player.currentBookCard?.title ?? " ")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 8)

                // v1.4.4：删掉条内 play/pause 圆钮。
                // 底部 dock 中间已经有一个播放键，条里再放一个就是两个入口做同一件事，
                // 用户截图明确反馈「重复」。播放/暂停统一由 dock 中间键承担。
                // 条内只保留「快进」——它和中间键不是同一动作。

                // 图标与实际动作对齐：画的是快进步数，不是"下一集"
                Button {
                    player.skip(true)
                } label: {
                    Image(systemName: "goforward.\(skipSeconds)")
                        .font(.system(size: 18))
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!player.canSeek)
                .accessibilityLabel("快进 \(skipSeconds) 秒")
            }
            // 高度由内容内在尺寸决定（封面 40 + 上下 8 = 56），
            // 不再用 frame(height:) 写死：写死之后外层再加 padding 就比 56 高，
            // dock 那边按 56 预留 → 两段叠在一起（用户截图蓝圈）。
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullScreen = true }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("展开播放页")
            .modifier(MiniBarLog())
        }
    }

    private var cover: some View {
        AsyncImage(url: URL(string: player.currentBookCard?.coverUrl ?? "")) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: Layout.radiusThumb)
                .fill(Layout.cardFill)
                .overlay(Image(systemName: "book.closed")
                    .font(.caption).foregroundStyle(.secondary))
        }
        .frame(width: Layout.miniBarCover, height: Layout.miniBarCover)
        .clipShape(RoundedRectangle(cornerRadius: Layout.radiusThumb))
    }

    private var skipSeconds: Int {
        let s = LocalStore.loadPlayPrefs().seekSeconds
        return s > 0 ? s : 10
    }

    /// Player 是 @Published 的 ObservableObject：状态一变 body 自己重算。
    /// error 保留：否则用户收起播放页后就再也找不到重试入口。
    private var shouldShow: Bool {
        switch player.state {
        case .playing, .paused, .loading, .error: return !player.nowPlaying.isEmpty
        case .stopped: return false
        }
    }
}

/// 迷你条的进出日志：只在真的挂上/卸载时打，避免 body 每帧重算都刷屏
private struct MiniBarLog: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { CrashLog.write("UI", "mini appear") }
            .onDisappear { CrashLog.write("UI", "mini disappear") }
    }
}
