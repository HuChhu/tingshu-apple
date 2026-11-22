import SwiftUI

/// 播放页：当前集、状态、进度条、错误。
/// 数据流：AlbumView 选集 → Player.playEpisode → SharedBridge.extract（引擎 级1→级3）→ AVPlayer。
/// 进度每 5 秒落 LocalStore，切后台或退出可在原位置续播。
struct PlayerView: View {
    @ObservedObject private var player = Player.shared
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            Image(systemName: icon)
                .font(.system(size: Layout.heroIcon(width)))
                .foregroundStyle(player.state == .error ? Color.red : Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: player.state == .playing)

            VStack(spacing: 6) {
                Text(player.nowPlaying.isEmpty ? "未选择曲目" : player.nowPlaying)
                    .font(.headline).multilineTextAlignment(.center).lineLimit(2)
                Text(player.state.rawValue)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .padding(.horizontal)

            if let err = player.errorText {
                Text(err).font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            // 进度条（拖动时用本地值，松手才 seek）
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { dragValue ?? player.position },
                        set: { dragValue = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let v = dragValue {
                            player.seek(toFraction: v)
                            dragValue = nil
                        }
                    }
                )
                .disabled(player.state != .playing && player.state != .paused)
                HStack {
                    Text(player.elapsedText).font(.caption2.monospacedDigit())
                    Spacer()
                    Text(player.durationText).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 28) {
                Button {
                    player.skip(false)
                } label: {
                    Image(systemName: "gobackward.\(seekSecs)").font(.title2)
                }
                .disabled(player.state == .stopped)

                Button {
                    if player.state == .playing { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: Layout.mainButton(width)))
                }
                .disabled(player.state == .stopped || player.state == .error || player.state == .loading)

                Button {
                    player.skip(true)
                } label: {
                    Image(systemName: "goforward.\(seekSecs)").font(.title2)
                }
                .disabled(player.state == .stopped)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.top, 24)
        .navigationTitle("播放")
    }

    /// 从设置读取快进快退秒数（对应安卓设置页第 8 项）
    private var seekSecs: Int {
        LocalStore.loadPlayPrefs().seekSeconds
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
