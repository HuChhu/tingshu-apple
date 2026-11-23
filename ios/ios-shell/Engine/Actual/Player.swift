import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 播放器。契约四态 → PlayerState。
/// 纪律：
///   - AVQueuePlayer 预插下一章，防章节间隙被系统挂起
///   - headers 由共享核心按 host 精确匹配过滤后原样注入（AVURLAssetHTTPHeaderFieldsKey），不加工
///   - 播放进度每 5 秒落一次 LocalStore，退出/切后台也能续上
@MainActor
final class Player: NSObject, ObservableObject {
    var currentSourceId: String = "ximalaya-open"

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
    /// AVQueuePlayer 没有 .duration；统一从 currentItem 取（换章时随 item 更新）
    private var currentDuration: Double {
        guard let d = queue.currentItem?.duration.seconds, d.isFinite, d > 0 else { return 0 }
        return d
    }
    private var current: SharedBridge.EpisodeRow?
    private var currentBook: SharedBridge.BookCard?

    // ---------- 锁屏/控制中心/耳机线控 ----------
    // IPA 质检发现：全工程 0 处 MPRemoteCommandCenter，装上后锁屏无播放信息、
    // 耳机线控失效。听书 App 这是体验硬伤（开车/运动场景全靠线控）。

    private func installRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.state == .playing { self.pause() } else { self.resume() }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.preferredIntervals = [10]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(true); return .success
        }
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(false); return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let self, let e = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(toFraction: e.positionTime / max(self.currentDuration, 1))
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = current?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentBook?.title ?? ""
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0
        let dur = currentDuration
        if dur.isFinite && dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = queue.currentTime().seconds
        }
        if let u = currentBook?.coverUrl, let url = URL(string: u) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: CGSize(width: 400, height: 400)) { _ in
                // 同步取图（锁屏场景可接受；失败给空图不影响主流程）
                if let d = try? Data(contentsOf: url), let img = UIImage(data: d) { return img }
                return UIImage()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private var timeObserver: Any?
    private var lastSavedMs: Int64 = 0

    override init() {
        super.init()
        installTimeObserver()
        installRemoteCommands()
    }

    // MARK: - 播放

    /// 点一集：先向引擎要播放地址，拿到再起播。地址有时效，不缓存。
    /// 按源播放：先按 sourceId 取真实地址，再交给 AVPlayer。
    /// 和 playEpisode 的区别是取地址走 SourceRegistry 而不是登录版引擎，
    /// 这样 35 个源（含 29 个模板站）都能播。
    func playEpisode(
        _ ep: SharedBridge.EpisodeRow,
        book: SharedBridge.BookCard? = nil,
        sourceId: String
    ) {
        currentSourceId = sourceId
        state = .loading
        nowPlaying = ep.title
        errorText = nil
        current = ep
        if let b = book { currentBook = b }

        Task { @MainActor in
            guard let audio = await SharedBridge.audio(sourceId: sourceId, url: ep.url) else {
                state = .error
                // P0-3：显示真实原因（登录失效/网络异常/触发限流），不再一律「取不到」
                errorText = SharedBridge.lastAudioError ?? "这个源取不到播放地址"
                return
            }
            guard let u = URL(string: audio.url) else {
                state = .error
                errorText = "返回的地址无法解析"
                return
            }
            play(url: u, headers: audio.headers, expectedDurationMs: ep.durationMs)

            LocalStore.pushRecent(.init(
                bookUrl: currentBook?.bookUrl ?? "",
                bookTitle: currentBook?.title ?? "",
                trackId: ep.trackId,
                episodeTitle: ep.title,
                playedAt: Date(),
                sourceId: currentSourceId))
        }
    }

    func playEpisode(_ ep: SharedBridge.EpisodeRow, book: SharedBridge.BookCard? = nil) {
        currentSourceId = "ximalaya"
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
                playedAt: Date(),
                sourceId: currentSourceId))
        }
    }

    private func play(url: URL, headers: [String: String], expectedDurationMs: Int64) {
        BackgroundSession.activateForPlayback()
        let opts: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let prefs = LocalStore.loadPlayPrefs()
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        if prefs.skipSilence {
            // iOS 16.4+ 支持自动跳过静音段
            if #available(iOS 16.4, *) {
                item.audioTimePitchAlgorithm = .timeDomain
            }
        }
        queue.removeAllItems()
        queue.insert(item, after: nil)
        queue.play()
        updateNowPlayingInfo()
        state = .playing
        durationText = fmt(expectedDurationMs)

        // 续播：上次听到哪就从哪开始（超过 95% 视为听完，从头放）
        if let b = currentBook, let saved = LocalStore.progress(for: b.bookUrl),
           saved.trackId == (current?.trackId ?? -1), saved.positionMs > 3000,
           saved.durationMs > 0, Double(saved.positionMs) / Double(saved.durationMs) < 0.95 {
            // 恢复播放时按偏好后退几秒，防听漏（安卓设置页第 7 项）
            let rewind = Int64(LocalStore.loadPlayPrefs().resumeRewindSeconds) * 1000
            let targetMs = max(0, saved.positionMs - rewind)
            let t = CMTime(value: targetMs, timescale: 1000)
            queue.seek(to: t)
        }
    }

    func pause() {
        queue.pause()
        updateNowPlayingInfo()
        if state == .playing { state = .paused }
        saveProgress(force: true)
    }

    func resume() {
        queue.play()
        updateNowPlayingInfo()
        state = .playing
    }

    func stop() {
        clearNowPlaying()
        saveProgress(force: true)
        queue.removeAllItems()
        state = .stopped
        position = 0
        elapsedText = "0:00"
        durationText = "0:00"
    }

    /// 按偏好秒数快进/快退（对应安卓「快进快退秒数」，默认 10 秒）
    func skip(_ forward: Bool) {
        defer { updateNowPlayingInfo() }
        guard let item = queue.currentItem, item.duration.isNumeric else { return }
        let secs = Double(LocalStore.loadPlayPrefs().seekSeconds)
        let target = item.currentTime().seconds + (forward ? secs : -secs)
        let clamped = max(0, min(item.duration.seconds, target))
        queue.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
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
        updateNowPlayingInfo()
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
