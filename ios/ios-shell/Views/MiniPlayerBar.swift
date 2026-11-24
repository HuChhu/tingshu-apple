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

                // 播放/暂停：44pt 热区（图标 28），点它不能同时触发条主体的展开
                Button {
                    if player.state == .playing { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: player.state == .playing
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.state == .playing ? "暂停" : "播放")

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
            .frame(height: Layout.miniBarHeight)
            .padding(.horizontal, 10)
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
