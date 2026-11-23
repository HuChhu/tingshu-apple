import SwiftUI
import UIKit

/// 迷你播放条：底部常驻，点开进全屏播放页（对标喜马拉雅：播放不进 Tab，用悬浮条 + 全屏页）。
/// 只在这一集真正开始播（或暂停中）时出现，避免空状态下挡住内容。
/// 底部安全区高度：MiniPlayerBar 要让开 TabBar + Home 指示条。
/// 本文件用了 SwiftUI + UIKit，Combine 的运算符一律不用（避免多一个 import）。
private extension UIApplication {
    var safeAreaInsetBottom: CGFloat {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}

struct MiniPlayerBar: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        Group {
            if shouldShow {
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: player.currentBookCard?.coverUrl ?? "")) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.nowPlaying)
                            .font(.caption).lineLimit(1)
                        Text(player.currentBookCard?.title ?? " ")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }

                    Spacer()

                    Button {
                        if player.state == .playing { player.pause() } else { player.resume() }
                    } label: {
                        Image(systemName: player.state == .playing
                              ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.skip(true)
                    } label: {
                        Image(systemName: "forward.end.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15)))
                .padding(.horizontal, 10)
                // 让开 TabBar：标准 tab bar 高 49pt，加底部安全区（mini 条之前被它盖住一半）
                .padding(.bottom, 49 + max(16, UIApplication.shared.safeAreaInsetBottom))
                .contentShape(Rectangle())
                .onTapGesture { player.showFullScreen = true }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shouldShow)
    }

    /// Player 是 @Published 的 ObservableObject：状态一变 body 自己重算，
    /// 不需要 Timer 轮询（原来 0.6 秒一次的 Timer 既费电又多一次 Combine 依赖）。
    private var shouldShow: Bool {
        switch player.state {
        case .playing, .paused, .loading: return !player.nowPlaying.isEmpty
        case .stopped, .error: return false
        }
    }
}
