import SwiftUI

/// 播放页占位（T05）。周3 闸口（M3）唯一验收：后台锁屏播放 ≥30s 出声。
/// 数据流：SharedBridge 取 ExtractedAudio(url, headers) → Player；
/// headers 由共享核心按 host 精确匹配过滤，壳侧原样注入、不再加工。
struct PlayerView: View {
    @State private var playing = false
    @State private var stateText = "待接框架"

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: playing ? "waveform" : "play.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(stateText).font(.headline)
            Button(playing ? "暂停（stub）" : "播放（stub）") {
                playing.toggle()
                if playing {
                    BackgroundSession.activateForPlayback()
                    stateText = "三件套已激活 · 待框架真 URL"
                } else {
                    Player.shared.pause()
                    stateText = "已暂停"
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("播放")
    }
}
