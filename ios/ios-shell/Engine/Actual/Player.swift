import Foundation
import AVFoundation

/// 触点 4/5：播放器。契约 PlaybackStateSink 四态 → PlayerState。
/// 纪律：AVQueuePlayer 预插下一章，防章节间隙被系统挂起；headers 由共享核心
/// 按 host 精确匹配过滤后原样注入（AVURLAssetHTTPHeaderFieldsKey），不加工。
@MainActor
final class Player: NSObject {
    static let shared = Player()

    enum PlayerState { case playing, paused, error, stopped }

    private let queue = AVQueuePlayer()
    var currentState: PlayerState {
        switch queue.timeControlStatus {
        case .playing: return .playing
        case .paused, .waitingToPlayAtSpecifiedRate: return .paused
        @unknown default: return .stopped
        }
    }

    /// 占位播放（T05）：验三件套与状态机；真 URL 待框架 extract 接通（M3 用例）。
    /// headers 注入点：AVURLAsset(url:, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    func playStub(url: URL, headers: [String: String] = [:]) {
        queue.insert(AVPlayerItem(url: url), after: nil)
        queue.play()
    }

    /// 预插下一章（防章节间隙挂起的关键，不留空档）
    func enqueueNext(url: URL) {
        queue.insert(AVPlayerItem(url: url), after: nil)
    }

    func pause() { queue.pause() }
    func stop() { queue.removeAllItems() }

    /// 打断恢复真身：interruption .shouldResume 到来时，队列里有章节才续播
    func resumeAfterInterruption() {
        guard !queue.items().isEmpty else { return }
        queue.play()
    }
}
