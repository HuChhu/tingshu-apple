import SwiftUI

/// 播放页：显示当前集、状态、错误。数据流：
/// ShelfView 选集 → Player.playEpisode → SharedBridge.extract（引擎 级1→级3）→ AVPlayer。
/// headers 由共享核心按 host 精确匹配过滤，壳侧原样注入、不再加工。
struct PlayerView: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(player.state == .error ? Color.red : Color.accentColor)

            Text(player.nowPlaying.isEmpty ? "未选择曲目" : player.nowPlaying)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(player.state.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))

            if let err = player.errorText {
                Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button {
                    if player.state == .playing { player.pause() } else { player.resume() }
                } label: {
                    Label(player.state == .playing ? "暂停" : "继续", systemImage: player.state == .playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.state == .stopped || player.state == .error || player.state == .loading)

                Button {
                    player.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(player.state == .stopped)
            }

            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("播放")
    }

    private var icon: String {
        switch player.state {
        case .playing: return "waveform"
        case .loading: return "hourglass"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .stopped: return "play.circle"
        }
    }
}
