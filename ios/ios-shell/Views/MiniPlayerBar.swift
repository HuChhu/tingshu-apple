import SwiftUI
import UIKit

/// 迷你播放条：底部常驻，点开进全屏播放页（对标喜马拉雅：播放不进 Tab，用悬浮条 + 全屏页）。
/// 出现条件：有当前集且状态不是 stopped（error 也保留 —— 用户收起了播放页还能从条上重试）。
/// 位置：ZStack(bottom) 里贴着 TabView 底边，再让开 TabBar（49pt）+ 底部安全区。
/// 本文件用了 SwiftUI + UIKit，Combine 的运算符一律不用（避免多一个 import）。
private extension UIApplication {
    /// 底部安全区（Home 指示条）
    var safeAreaInsetBottom: CGFloat {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    /// TabBar 实际高度。标准 49pt，但 iPad / 横屏 / 「大图标」无障碍模式下会变高，
    /// 所以优先问 keyWindow 上真实的 UITabBar；问不到再退回 49。
    var tabBarHeight: CGFloat {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first?.windows.first else { return 49 }
        for view in window.subviews {
            if let tab = findTabBar(in: view) {
                return max(49, tab.bounds.height)
            }
        }
        return 49
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let tab = view as? UITabBar { return tab }
        for sub in view.subviews {
            if let hit = findTabBar(in: sub) { return hit }
        }
        return nil
    }
}

struct MiniPlayerBar: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        Group {
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

                    // 图标与实际动作对齐：原来画的是「下一集」(forward.end.fill)，
                    // 实际只快进 N 秒 → 用户以为坏了。这里改成和秒数一致的 goforward.N。
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Layout.radiusBar))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.radiusBar)
                        .stroke(Color.secondary.opacity(0.15))
                )
                // 条底部 2pt 进度线（方案 §3.5：进度跟条内容对齐）
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(0, geo.size.width * CGFloat(progressFraction)), height: 2)
                            .offset(y: -1)
                    }
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, Layout.miniBarSideMargin)
                .padding(.bottom, Layout.miniBarGap + UIApplication.shared.safeAreaInsetBottom)
                // 让开 TabBar：用实际量到的 tab bar 高度，不再写死 49
                .offset(y: -UIApplication.shared.tabBarHeight)
                .contentShape(Rectangle())
                .onTapGesture { player.showFullScreen = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("展开播放页")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.26), value: shouldShow)
        .onAppear { CrashLog.write("UI", "mini appear") }
        .onDisappear { CrashLog.write("UI", "mini disappear") }
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

    /// 0...1，给底部进度线用
    private var progressFraction: Double {
        let p = player.position
        return p.isFinite ? min(1, max(0, p)) : 0
    }

    private var skipSeconds: Int {
        let s = LocalStore.loadPlayPrefs().seekSeconds
        return s > 0 ? s : 10
    }

    /// Player 是 @Published 的 ObservableObject：状态一变 body 自己重算，
    /// 不需要 Timer 轮询（原来 0.6 秒一次的 Timer 既费电又多一次 Combine 依赖）。
    /// error 保留：否则用户收起播放页后就再也找不到重试入口（方案 §七「状态/可达性」）。
    private var shouldShow: Bool {
        switch player.state {
        case .playing, .paused, .loading, .error: return !player.nowPlaying.isEmpty
        case .stopped: return false
        }
    }
}
