import Foundation
import AVFoundation

/// 播放器。契约四态 → PlayerState。
/// 纪律：AVQueuePlayer 预插下一章，防章节间隙被系统挂起；headers 由共享核心
/// 按 host 精确匹配过滤后原样注入（AVURLAssetHTTPHeaderFieldsKey），不加工。
@MainActor
final class Player: NSObject, ObservableObject {
    static let shared = Player()

    enum PlayerState: String { case playing = "播放中", paused = "已暂停", loading = "解析地址…", error = "播放失败", stopped = "已停止" }

    @Published private(set) var state: PlayerState = .stopped
    @Published private(set) var nowPlaying: String = ""
    @Published private(set) var errorText: String?

    private let queue = AVQueuePlayer()

    /// 点一集：先向引擎要播放地址，拿到再起播。
    /// 地址是时效的（expiresInSeconds），所以每次点都重新提取，不缓存。
    func playEpisode(_ ep: SharedBridge.EpisodeRow) {
        state = .loading
        nowPlaying = ep.title
        errorText = nil

        // 引擎输入三形态：裸 trackId 直通 / 数字 / 完整 url。
        // 这里优先用 trackId（详情页已给），没有再退回 url 形态。
        let input = ep.trackId > 0 ? String(ep.trackId) : ep.url

        Task { @MainActor in
            guard let audio = await SharedBridge.extract(url: input) else {
                state = .error
                errorText = "取播放地址失败（可能需登录或该集受限）"
                return
            }
            guard let u = URL(string: audio.url) else {
                state = .error
                errorText = "引擎返回的地址无法解析"
                return
            }
            play(url: u, headers: audio.headers)
        }
    }

    private func play(url: URL, headers: [String: String]) {
        BackgroundSession.activateForPlayback()
        let opts: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: opts))
        queue.removeAllItems()
        queue.insert(item, after: nil)
        queue.play()
        state = .playing
    }

    func pause() {
        queue.pause()
        if state == .playing { state = .paused }
    }

    func resume() {
        queue.play()
        state = .playing
    }

    func stop() {
        queue.removeAllItems()
        state = .stopped
    }

    /// 打断恢复：interruption .shouldResume 到来时，队列里有章节才续播
    func resumeAfterInterruption() {
        guard !queue.items().isEmpty else { return }
        queue.play()
        state = .playing
    }
}
