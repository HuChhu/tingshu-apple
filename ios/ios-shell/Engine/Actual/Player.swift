import Foundation
import AVFoundation

/// 播放器。契约四态 → PlayerState。
/// 纪律：
///   - AVQueuePlayer 预插下一章，防章节间隙被系统挂起
///   - headers 由共享核心按 host 精确匹配过滤后原样注入（AVURLAssetHTTPHeaderFieldsKey），不加工
///   - 播放进度每 5 秒落一次 LocalStore，退出/切后台也能续上
@MainActor
final class Player: NSObject, ObservableObject {
    static let shared = Player()

    enum PlayerState: String {
        case playing = "播放中", paused = "已暂停", loading = "解析地址…",
             error = "播放失败", stopped = "已停止"
    }

    @Published private(set) var state: PlayerState = .stopped
    @Published private(set) var nowPlaying: String = ""
    @Published private(set) var errorText: String?
    @Published private(set) var position: Double = 0        // 0...1
    @Published private(set) var elapsedText: String = "0:00"
    @Published private(set) var durationText: String = "0:00"

    private let queue = AVQueuePlayer()
    private var current: SharedBridge.EpisodeRow?
    private var currentBook: SharedBridge.BookCard?
    private var timeObserver: Any?
    private var lastSavedMs: Int64 = 0

    override init() {
        super.init()
        installTimeObserver()
    }

    // MARK: - 播放

    /// 点一集：先向引擎要播放地址，拿到再起播。地址有时效，不缓存。
    func playEpisode(_ ep: SharedBridge.EpisodeRow, book: SharedBridge.BookCard? = nil) {
        state = .loading
        nowPlaying = ep.title
        errorText = nil
        current = ep
        if let b = book { currentBook = b }

        let input = ep.trackId > 0 ? String(ep.trackId) : ep.url

        Task { @MainActor in
            guard let audio = await SharedBridge.extract(url: input) else {
                state = .error
                errorText = "取播放地址失败（该集可能需要登录或已下架）"
                return
            }
            guard let u = URL(string: audio.url) else {
                state = .error
                errorText = "引擎返回的地址无法解析"
                return
            }
            play(url: u, headers: audio.headers, expectedDurationMs: ep.durationMs)

            LocalStore.pushRecent(.init(
                bookUrl: currentBook?.bookUrl ?? "",
                bookTitle: currentBook?.title ?? "",
                trackId: ep.trackId,
                episodeTitle: ep.title,
                playedAt: Date()))
        }
    }

    private func play(url: URL, headers: [String: String], expectedDurationMs: Int64) {
        BackgroundSession.activateForPlayback()
        let opts: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: opts))
        queue.removeAllItems()
        queue.insert(item, after: nil)
        queue.play()
        state = .playing
        durationText = fmt(expectedDurationMs)

        // 续播：上次听到哪就从哪开始（超过 95% 视为听完，从头放）
        if let b = currentBook, let saved = LocalStore.progress(for: b.bookUrl),
           saved.trackId == (current?.trackId ?? -1), saved.positionMs > 3000,
           saved.durationMs > 0, Double(saved.positionMs) / Double(saved.durationMs) < 0.95 {
            let t = CMTime(value: saved.positionMs, timescale: 1000)
            queue.seek(to: t)
        }
    }

    func pause() {
        queue.pause()
        if state == .playing { state = .paused }
        saveProgress(force: true)
    }

    func resume() {
        queue.play()
        state = .playing
    }

    func stop() {
        saveProgress(force: true)
        queue.removeAllItems()
        state = .stopped
        position = 0
        elapsedText = "0:00"
        durationText = "0:00"
    }

    func seek(toFraction f: Double) {
        guard let item = queue.currentItem else { return }
        let d = item.duration
        guard d.isNumeric else { return }
        let secs = d.seconds * max(0, min(1, f))
        queue.seek(to: CMTime(seconds: secs, preferredTimescale: 600))
    }

    /// 打断恢复：interruption .shouldResume 到来时，队列里有章节才续播
    func resumeAfterInterruption() {
        guard !queue.items().isEmpty else { return }
        queue.play()
        state = .playing
    }

    // MARK: - 进度

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = queue.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            let d = self.queue.currentItem?.duration
            if let d, d.isNumeric, d.seconds > 0 {
                self.position = min(1.0, max(0, t.seconds / d.seconds))
                self.elapsedText = self.fmt(Int64(t.seconds * 1000))
                self.durationText = self.fmt(Int64(d.seconds * 1000))
            }
            self.saveProgress(force: false)
        }
    }

    private func saveProgress(force: Bool) {
        guard let ep = current, let book = currentBook, queue.currentItem != nil else { return }
        let nowMs = Int64(queue.currentTime().seconds * 1000)
        guard nowMs > 0 else { return }
        if !force, abs(nowMs - lastSavedMs) < 5_000 { return }
        lastSavedMs = nowMs

        let durMs: Int64 = {
            if let d = queue.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                return Int64(d.seconds * 1000)
            }
            return ep.durationMs
        }()

        LocalStore.saveProgress(.init(
            bookUrl: book.bookUrl, title: book.title,
            trackId: ep.trackId, episodeTitle: ep.title,
            positionMs: nowMs, durationMs: durMs, updatedAt: Date()))
    }

    private func fmt(_ ms: Int64) -> String {
        let s = ms / 1000
        if s >= 3600 { return String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60) }
        return String(format: "%d:%02d", s/60, s%60)
    }
}
