import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// 播放器。契约四态 → PlayerState。
/// 纪律：
///   - AVQueuePlayer 预插下一章，防章节间隙被系统挂起
///   - headers 由共享核心按 host 精确匹配过滤后原样注入（AVURLAssetHTTPHeaderFieldsKey），不加工
///   - 播放进度每 5 秒落一次 LocalStore，退出/切后台也能续上
/// 加固（播放链路异常位）：
///   - item.status / AVPlayerItemFailedToPlayToEndTime / AVPlayerItemPlaybackStalled 三路监听，
///     404、HTML 错误页、断网都落到 .error 并给真实原因，不再永久 loading
///   - 每次换章先 detach 旧 item 的观察（KVO + 通知）、清 item 级 timeObserver，防重复注册
///   - state 只走 apply() 单一入口，允许集合显式列出，卡死态可在 error 里点播放重试
///   - 播放地址请求带代际号，快速连点两集时晚到的旧响应直接丢弃
///   - 切章 / 暂停 / 停止 / 后台 / 前后台切换 / 即将退出，全部强制落一次进度
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
    /// 是否展示全屏播放页（迷你条点击 → true；全屏页下拉关闭 → false）
    /// 放在 Player 上而不是根视图，是因为「播完自动进全屏」「错误页跳播放」都要能触发它。
    @Published var showFullScreen: Bool = false
    @Published private(set) var errorText: String?
    @Published private(set) var position: Double = 0        // 0...1
    @Published private(set) var elapsedText: String = "0:00"
    @Published private(set) var durationText: String = "0:00"
    /// 失败后可点的补救动作（有值 = 播放页显示「重试」按钮）
    @Published private(set) var canRetry: Bool = false

    private let queue = AVQueuePlayer()
    /// 改变播放位置命令 / 进度条的分母（P2-6）：
    /// currentDuration 在空队列或刚起播时是 0，直接 max(d, 1) 只能挡住 0，挡不住 NaN，
    /// 结果 0/1 或 NaN 传给 seek，进度条不收敛。这里先判 isFinite && > 0。
    private var safeDuration: Double {
        let d = currentDuration
        guard d.isFinite, d > 0 else { return 1 }
        return d
    }
    /// AVQueuePlayer 没有 .duration；统一从 currentItem 取（换章时随 item 更新）
    private var currentDuration: Double {
        guard let d = queue.currentItem?.duration.seconds, d.isFinite, d > 0 else { return 0 }
        return d
    }
    private var current: SharedBridge.EpisodeRow?
    private var currentBook: SharedBridge.BookCard?

    // ---------- 状态机 ----------
    // 原实现里 state 有 14 处直接赋值，.error 之后只有重新点一集才能动，
    // 播放页的播放键在 .error 时被 disabled —— 用户就卡死在死界面上。
    // 现在只走 apply()：单一入口 + 显式允许集合，越界动作被拒绝而不是静默写脏。

    private func apply(_ next: PlayerState) {
        guard next != state else { return }
        let allowed: [PlayerState: Set<PlayerState>] = [
            .stopped: [.loading, .stopped],
            .loading: [.playing, .paused, .error, .stopped],
            .playing: [.paused, .loading, .error, .stopped],
            .paused:  [.playing, .loading, .error, .stopped],
            // 失败态只能被「重新播」「显式重试」「停止」带走，杜绝 loading 卡死
            .error:   [.loading, .stopped, .error]
        ]
        guard (allowed[state] ?? []).contains(next) else {
            #if DEBUG
            debugPrint("[Player] 拒绝非法状态迁移 " + state.rawValue + " -> " + next.rawValue)
            #endif
            return
        }
        state = next
        if next != .error { canRetry = false }
        // 注意：这里不直接刷锁屏信息。apply 在 init 的观察回调里也会触发，
        // 那时 self 还没完全构造好；统一由各动作在改完状态后显式刷新。
    }

    /// 取播放地址失败 → 有集在手就允许重试
    private func failAddress(_ msg: String) {
        CrashLog.playbackFailed(
            book: currentBook?.title ?? "?",
            episode: current?.title ?? "?",
            trackId: current?.trackId ?? 0,
            source: currentSourceId, reason: "ADDR: " + msg)
        errorText = msg
        canRetry = (current != nil)
        resetPipeline()          // 连地址都没拿到，旧 item 必须清掉，否则界面还会插一句旧集
        apply(.error)
        updateNowPlayingInfo()
    }

    /// 播放链路失败 → 记原因、落进度、给重试
    private func failPlayback(_ msg: String) {
        CrashLog.playbackFailed(
            book: currentBook?.title ?? "?",
            episode: current?.title ?? "?",
            trackId: current?.trackId ?? 0,
            source: currentSourceId, reason: "PLAY: " + msg)
        saveProgress(force: true)
        errorText = msg
        canRetry = (current != nil)
        // 失败即清队列：AVQueuePlayer 留着 failed item 时会一直挂在 currentItem 上，
        // 后续 resume/skip 全都作用在这个死 item，表现为「点了没反应」
        resetPipeline()
        apply(.error)
        updateNowPlayingInfo()   // 锁屏上的比例要反映「停了」，不能还挂着 playing
    }

    /// 播放页「重试」按钮入口：地址过期/网络恢复后重新取地址起播
    func retry() {
        guard let ep = current else { return }
        playEpisode(ep, book: currentBook, sourceId: currentSourceId)
    }

    // ---------- 锁屏/控制中心/耳机线控 ----------
    // IPA 质检发现：全工程 0 处 MPRemoteCommandCenter，装上后锁屏无播放信息、
    // 耳机线控失效。听书 App 这是体验硬伤（开车/运动场景全靠线控）。
    // 闭包型 target 无法 removeTarget(nil)，object 换成 Player.shared 后，
    // 后续 alloc 出来的实例不再二次挂载；当前远程命令响应一律先查 isLive 守卫。

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    private func installRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        let guardCmd: () -> Bool = { Player.shared.isLive }

        addRemote(cc.playCommand, guard: guardCmd) { [weak self] _ in
            self?.resume(); return .success
        }
        addRemote(cc.pauseCommand, guard: guardCmd) { [weak self] _ in
            self?.pause(); return .success
        }
        addRemote(cc.togglePlayPauseCommand, guard: guardCmd) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.state == .playing { self.pause() } else { self.resume() }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.preferredIntervals = [10]
        addRemote(cc.skipForwardCommand, guard: guardCmd) { [weak self] _ in
            self?.skip(true); return .success
        }
        addRemote(cc.skipBackwardCommand, guard: guardCmd) { [weak self] _ in
            self?.skip(false); return .success
        }
        addRemote(cc.changePlaybackPositionCommand, guard: guardCmd) { [weak self] ev in
            guard let self, let e = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            // P2-6：分母不能是 0/NaN —— safeDuration 已判 isFinite 且 > 0
            self.seek(toFraction: e.positionTime / self.safeDuration)
            return .success
        }
        // 失败态下锁屏也能重试（不用点亮屏幕回 App）
        addRemote(cc.playCommand, guard: { Player.shared.state == .error }) { _ in
            Player.shared.retry(); return .success
        }
    }

    private func addRemote(
        _ cmd: MPRemoteCommand,
        guard liveGuard: @escaping () -> Bool,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        // P1-04：用 addTarget(_:action:) 而不是闭包。
        // selector 由 Objective-C 运行时在主线程调用，天然隔离正确。
        // 闭包方式可能在任意线程触发，导致 @MainActor 越界。
        let token = cmd.addTarget(self, action: #selector(handleRemoteCommand(_:)))
        remoteTargets.append((cmd, token))
        // 保存 handler 供 selector 调用
        remoteHandlers[cmd] = { ev in
            guard liveGuard() else { return .commandFailed }
            return handler(ev)
        }
    }
    
    private var remoteHandlers: [MPRemoteCommand: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus] = [:]
    
    @objc private func handleRemoteCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        let cmd = event.command
        return remoteHandlers[cmd]?(event) ?? .commandFailed
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = current?.title ?? ""
        info[MPMediaItemPropertyArtist] = currentBook?.title ?? ""
        // 失败/停止时锁屏不能显示「正在播放」，否则系统会持续把 App 当活动播放器
        let live = (state == .playing)
        info[MPNowPlayingInfoPropertyPlaybackRate] = live ? 1.0 : 0.0
        let dur = currentDuration
        if dur.isFinite && dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = queue.currentTime().seconds
        }
        if live, let u = currentBook?.coverUrl, let url = URL(string: u) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(url)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info.isEmpty ? nil : info
    }

    /// 封面异步取 + 进程内缓存：原实现在 MPMediaItemArtwork 闭包里同步
    /// Data(contentsOf:) —— 锁屏每次布局都会在主线程上发起一次网络请求，
    /// 弱网下直接触发 watchdog 掉帧；断网时每次再等一轮超时。
    private static let artworkLock = NSLock()
    private static var artworkCache: [String: UIImage] = [:]

    private static func makeArtwork(_ url: URL) -> MPMediaItemArtwork {
        let key = url.absoluteString
        artworkLock.lock()
        let cached = artworkCache[key]
        artworkLock.unlock()
        return MPMediaItemArtwork(boundsSize: CGSize(width: 400, height: 400)) { size in
            if let img = cached { return img }
            artworkLock.lock()
            let hit = artworkCache[key]
            artworkLock.unlock()
            if let hit { return hit }
            if let d = try? Data(contentsOf: url), let img = UIImage(data: d) {
                artworkLock.lock(); artworkCache[key] = img; artworkLock.unlock()
                return img
            }
            return UIImage()
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private var timeObserver: Any?
    /// 绑在当前 item 上的 timeObserver（队列条数变化时系统会把实例 observer 摘掉）
    private var itemObserver: Any?
    private weak var observedItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var itemNotificationTokens: [NSObjectProtocol] = []
    private var lastSavedMs: Int64 = 0
    /// 播放地址请求代际：每点一集 +1，晚到的旧响应丢弃
    private var requestGeneration: Int = 0
    /// 正在后台挂着等地址的那一集（不落进度，避免把续播点写到错误位置）
    private var requestingEpisode = false

    /// 快进/快退是否可用：只有真的挂着 item 才能 seek（error/stopped 时队列是空的）
    var canSeek: Bool {
        guard state == .playing || state == .paused else { return false }
        return queue.currentItem != nil
    }

    /// 远程命令/后台回调只对活着的那个实例生效
    private var isLive: Bool { Player.shared === self }

    // ===== 睡眠定时 =====
    /// 按时间停：到点执行的截止时刻
    private var sleepDeadline: Date?
    /// 按章节停：还剩几章（<0 表示没启用）
    private var sleepChaptersLeft: Int = -1

    /// 启动定时（minutes > 0 用时间；chapters > 0 用章节，二者取一个）
    func startSleepTimer(minutes: Int, chapters: Int) {
        var prefs = LocalStore.loadPlayPrefs()
        if minutes > 0 {
            sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepChaptersLeft = -1
            prefs.sleepLastMinutes = minutes
        } else if chapters > 0 {
            sleepDeadline = nil
            sleepChaptersLeft = chapters
            prefs.sleepLastChapters = chapters
        }
        LocalStore.savePlayPrefs(prefs)
        scheduleSleepCheck()
    }

    /// 取消定时
    func cancelSleepTimer() {
        sleepDeadline = nil
        sleepChaptersLeft = -1
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    /// 按章节：消耗一章；返回 true 表示该停了
    private func consumeSleepChapter() -> Bool {
        guard sleepChaptersLeft > 0 else { return false }
        sleepChaptersLeft -= 1
        return sleepChaptersLeft == 0
    }

    private var sleepTimer: Timer?

    private func scheduleSleepCheck() {
        sleepTimer?.invalidate()
        guard let deadline = sleepDeadline else { sleepTimer = nil; return }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { pause(); cancelSleepTimer(); return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pause()
            self.cancelSleepTimer()
        }
    }

    /// 重启 App 后按上次设置重新定时（prefs.sleepAutoEnable）
    func restoreSleepTimerIfNeeded() {
        let prefs = LocalStore.loadPlayPrefs()
        guard prefs.sleepAutoEnable else { return }
        if prefs.sleepLastMinutes > 0 {
            startSleepTimer(minutes: prefs.sleepLastMinutes, chapters: 0)
        }
    }

    /// 当前书生效的播放配置（专辑值 > 全局默认）
    private var effectivePlayback: LocalStore.AlbumPlayback {
        guard let b = currentBook else {
            let prefs = LocalStore.loadPlayPrefs()
            var d = LocalStore.AlbumPlayback()
            d.speed = prefs.defaultSpeed
            d.skipIntroSec = prefs.defaultSkipIntroSec
            d.skipOutroSec = prefs.defaultSkipOutroSec
            d.volumeGainDb = prefs.volumeGainDb
            return d
        }
        let key = BookKey(sourceId: currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)
        return LocalStore.effective(for: key, prefs: LocalStore.loadPlayPrefs())
    }

    // ===== 供 UI 读取的只读快照 =====

    /// 当前生效倍速（UI 显示）
    var currentSpeed: Double { effectivePlayback.speed }
    /// 当前是否倒序
    var isReverseOrder: Bool { effectivePlayback.reverseOrder }
    /// 当前播放的书（播放页读取配置用）
    var currentBookCard: SharedBridge.BookCard? { currentBook }
    /// 定时剩余文案：按时间显示 "mm:ss"，按章节显示 "剩 N 章"，没启用返回 nil
    var sleepRemainingText: String? {
        if let d = sleepDeadline {
            let left = Int(max(0, d.timeIntervalSinceNow))
            return String(format: "定时 %d:%02d", left / 60, left % 60)
        }
        if sleepChaptersLeft > 0 { return "剩 \(sleepChaptersLeft) 章" }
        return nil
    }

    /// 运行时改倍速（播放页调用，同时写回专辑配置）
    func setSpeed(_ v: Double) {
        let clamped = min(3.0, max(0.5, v))
        queue.rate = Float(clamped)
        persistPlayback { $0.speed = clamped }
    }

    /// 运行时改跳过片头/片尾
    func setSkip(intro: Int?, outro: Int?) {
        persistPlayback {
            if let i = intro { $0.skipIntroSec = max(0, i) }
            if let o = outro { $0.skipOutroSec = max(0, o) }
        }
    }

    /// 倒序播放
    func setReverseOrder(_ on: Bool) {
        persistPlayback { $0.reverseOrder = on }
    }

    private func persistPlayback(_ mutate: (inout LocalStore.AlbumPlayback) -> Void) {
        guard let b = currentBook else { return }
        let key = BookKey(sourceId: currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)
        var cur = LocalStore.albumPlayback(for: key) ?? effectivePlayback
        mutate(&cur)
        LocalStore.saveAlbumPlayback(cur, for: key)
    }

    override init() {
        super.init()
        installTimeObserver()
        installRemoteCommands()
        wireLifecycle()
        updateNowPlayingInfo()
    }

    deinit {
        // Player.shared 是单例，deinit 实际只在「有代码 new 了第二个 Player」时触发；
        // 即便如此，也把最后一条进度和 observer 收拾干净，避免多实例场景留下脏 token。
        // deinit 是 nonisolated，不能调 @MainActor 方法。
        // 直接写 UserDefaults（线程安全，无需主线程）。
        if let b = currentBook, let ep = current {
            let lastMs = Int64(queue.currentTime().seconds * 1000)
            UserDefaults.standard.set(
                ["trackId": ep.trackId, "positionMs": lastMs, "bookUrl": b.bookUrl],
                forKey: "lastPlayback_" + b.bookUrl)
        }
        NotificationCenter.default.removeObserver(self)          // 闭包式 addObserver 的 token 已由系统回收
    }
    // MARK: - 播放

    /// 点一集：先向引擎要播放地址，拿到再起播。地址有时效，不缓存。
    /// 按源播放：先按 sourceId 取真实地址，再交给 AVPlayer。
    /// 和 playEpisode 的区别是取地址走 SourceRegistry 而不是登录版引擎，
    /// 这样 35 个源（含 29 个模板站）都能播。
    func playEpisode(
        _ ep: SharedBridge.EpisodeRow,
        book: SharedBridge.BookCard? = nil,
        sourceId: String,
        episodes: [SharedBridge.EpisodeRow]? = nil
    ) {
        currentSourceId = sourceId
        // 关键：把整本集列表存进 currentEpisodes，否则自动连播/倒序永远拿不到"下一集"
        if let list = episodes, !list.isEmpty { currentEpisodes = list }
        beginRequest(ep, book: book)

        let gen = requestGeneration
        let src = sourceId
        let url = ep.url
        Task { @MainActor in
            // 集 url 可能是网页详情页（免登录专辑接口不给 playUrl 时）
            // 先用 trackId 换成 /sound/{id}，再让引擎按 track 解析
            var input = url
            if SharedBridge.looksLikeWebPage(input), ep.trackId > 0 {
                input = "https://www.ximalaya.com/sound/\(ep.trackId)"
            }
            var audio = await SharedBridge.audio(sourceId: src, url: input)

            // 引擎拿不到：三种兜底依次试，任何一条成功就能播
            // ① 登录版引擎按 trackId 直取（Cookie 已注入时通常最快）
            if audio == nil, ep.trackId > 0 {
                audio = await SharedBridge.extract(url: String(ep.trackId))
            }
            // ② 换免登录源再试一次（登录版被风控时这条常能过）
            if audio == nil, src != "ximalaya-open" {
                audio = await SharedBridge.audio(sourceId: "ximalaya-open", url: input)
            }
            // ③ WebView 嗅探（前端渲染的站、直链藏在 JS 里的站）
            if audio == nil, input.hasPrefix("http") {
                if let sniffed = await SharedBridge.sniffAudio(pageUrl: input) {
                    audio = SharedBridge.makeAudio(url: sniffed)
                }
            }
            
            guard let audio = audio else {
                guard gen == self.requestGeneration else { return }
                self.requestingEpisode = false
                // P0-3：显示真实原因（登录失效/网络异常/触发限流），不再一律「取不到」
                self.failAddress(SharedBridge.lastAudioError ?? "这个源取不到播放地址")
                return
            }
            guard gen == self.requestGeneration else { return }   // 用户已经点了别的集
            guard let u = URL(string: audio.url) else {
                self.requestingEpisode = false
                self.failAddress("返回的地址无法解析")
                return
            }
            self.startItem(url: u, headers: audio.headers, ep: ep)
        }
    }

    func playEpisode(_ ep: SharedBridge.EpisodeRow, book: SharedBridge.BookCard? = nil) {
        currentSourceId = "ximalaya"
        beginRequest(ep, book: book)

        let gen = requestGeneration
        let input = ep.trackId > 0 ? String(ep.trackId) : ep.url
        Task { @MainActor in
            guard let audio = await SharedBridge.extract(url: input) else {
                guard gen == self.requestGeneration else { return }
                self.requestingEpisode = false
                self.failAddress("取播放地址失败（该集可能需要登录或已下架）")
                return
            }
            guard gen == self.requestGeneration else { return }
            guard let u = URL(string: audio.url) else {
                self.requestingEpisode = false
                self.failAddress("引擎返回的地址无法解析")
                return
            }
            self.startItem(url: u, headers: audio.headers, ep: ep)
        }
    }

    /// 两条 playEpisode 的公共前置：切章先落旧进度 → 换书判定 → 挂 loading → 换代际
    private func beginRequest(_ ep: SharedBridge.EpisodeRow, book: SharedBridge.BookCard?) {
        saveProgress(force: true)          // 切章：旧集进度必须落地，不能被新集覆盖
        // P1-5：currentBook 之前是「粘性」的 —— 只在新参数非 nil 时覆盖，
        // 跨书播放时（新书没传 book，或传的是同一本书的旧卡）会残留上一本的
        // bookUrl/title，导致续播读的是上一本的位置、lockscreen 显示上一本书名。
        // 这里按 bookUrl 判定换书：url 不同就整本换掉，并清掉续播写点。
        if let b = book {
            let prev = currentBook
            let switchedBook = (prev == nil) || (prev?.bookUrl != b.bookUrl)
            currentBook = b
            if switchedBook {
                lastSavedMs = 0
                position = 0
                elapsedText = "0:00"
                durationText = "0:00"
            }
        } else {
            // 没传书：说明调用方不关心书身份，旧书上下文一律作废，别让重试读到错的书
            currentBook = nil
            lastSavedMs = 0
        }
        requestGeneration &+= 1
        requestingEpisode = true
        // .error 不能直接跳 .loading（apply 的允许集合），先退到 stopped 再进 loading
        if state == .error { apply(.stopped) }
        errorText = nil
        nowPlaying = ep.title
        current = ep
        apply(.loading)
        updateNowPlayingInfo()
    }


    // ---------- 音频缓存辅助（P0-00 补定义） ----------
    
    private func cachedURL(for url: URL) -> URL? {
        guard let book = currentBook, let ep = current else { return nil }
        return AudioCache.cachedFile(bookUrl: book.bookUrl, trackId: ep.trackId)
    }
    
    private func cacheInBackground(url: URL, headers: [String: String]) {
        guard let book = currentBook, let ep = current else { return }
        let bookUrl = book.bookUrl
        let trackId = ep.trackId
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension

        Task.detached(priority: .utility) {
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let dest = AudioCache.file(bookUrl: bookUrl, trackId: trackId, ext: ext)
            let temp = dest.appendingPathExtension(UUID().uuidString + ".part")
            do {
                let (download, response) = try await URLSession.shared.download(for: req)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: download)
                    return
                }
                defer { try? FileManager.default.removeItem(at: temp) }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: download, to: temp)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: temp, to: dest)
                AudioCache.trimBook(bookUrl: bookUrl, keep: 3)
            } catch {
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }
    
    /// 用本地文件起播（缓存命中时走这里）
    private func startItemWithLocalFile(_ item: AVPlayerItem, ep: SharedBridge.EpisodeRow) {
        CrashLog.write("PLAY", "start local track=\(ep.trackId) src=\(currentSourceId) scheme=file host=")
        let prefs = LocalStore.loadPlayPrefs()
        if prefs.skipSilence, #available(iOS 16.4, *) {
            item.audioTimePitchAlgorithm = .timeDomain
        }
        detachItem()
        queue.removeAllItems()
        installTimeObserver()
        queue.insert(item, after: nil)
        attachItem(item)
        installItemTimeObserver()
        queue.play()
        errorText = nil
        durationText = fmt(ep.durationMs)
        // 倍速：专辑值 > 全局默认（这里再兜一次，AVPlayer 对 rate<=0/NaN 不友好）
        let sp = effectivePlayback.speed
        queue.rate = Float(sp.isFinite && sp > 0 ? min(3.0, max(0.5, sp)) : 1.0)
        apply(.playing)
        CrashLog.write("PLAY", "start ready track=\(ep.trackId) src=\(currentSourceId)")
        
        if let b = currentBook,
           let saved = LocalStore.progress(for: BookKey(sourceId: currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)),
           saved.trackId == (current?.trackId ?? -1), saved.positionMs > 3000,
           saved.durationMs > 0, Double(saved.positionMs) / Double(saved.durationMs) < 0.95 {
            let rewind = Int64(LocalStore.loadPlayPrefs().resumeRewindSeconds) * 1000
            let targetMs = max(0, saved.positionMs - rewind)
            queue.seek(to: CMTime(value: targetMs, timescale: 1000))
            position = min(1.0, Double(targetMs) / Double(max(saved.durationMs, 1)))
            elapsedText = fmt(targetMs)
        }
        
        LocalStore.pushRecent(.init(
            bookUrl: currentBook?.bookUrl ?? "",
            bookTitle: currentBook?.title ?? "",
            trackId: ep.trackId,
            episodeTitle: ep.title,
            playedAt: Date(),
            sourceId: currentSourceId, episodeUrl: ep.url,
            coverUrl: currentBook?.coverUrl ?? ""))
    }

    private func startItem(url: URL, headers: [String: String], ep: SharedBridge.EpisodeRow) {
        CrashLog.write("PLAY", "start remote track=\(ep.trackId) src=\(currentSourceId) scheme=\(url.scheme ?? "") host=\(url.host ?? "")")
        requestingEpisode = false
        BackgroundSession.activateForPlayback()
        
        // 缓存优先：已缓存的集直接播本地文件（离线可用）
        if let cached = cachedURL(for: url), FileManager.default.fileExists(atPath: cached.path) {
            let item = AVPlayerItem(url: cached)
            startItemWithLocalFile(item, ep: ep)
            return
        }
        
        let opts: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let prefs = LocalStore.loadPlayPrefs()
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        
        // 边播边缓存：起播后异步下载
        if AudioCache.loadSettings().autoCacheNext {
            cacheInBackground(url: url, headers: headers)
        }
        if prefs.skipSilence {
            // iOS 16.4+ 支持自动跳过静音段
            if #available(iOS 16.4, *) {
                item.audioTimePitchAlgorithm = .timeDomain
            }
        }
        // 关键：先摘旧 item 的全部观察，再换；队列若被清空过，实例秒表要重装
        detachItem()
        queue.removeAllItems()
        installTimeObserver()
        queue.insert(item, after: nil)
        attachItem(item)
        installItemTimeObserver()
        queue.play()
        errorText = nil
        durationText = fmt(ep.durationMs)
        apply(.playing)

        // 续播：上次听到哪就从哪开始（超过 95% 视为听完，从头放）
        if let b = currentBook, let saved = LocalStore.progress(for: b.bookUrl),
           saved.trackId == (current?.trackId ?? -1), saved.positionMs > 3000,
           saved.durationMs > 0, Double(saved.positionMs) / Double(saved.durationMs) < 0.95 {
            // 恢复播放时按偏好后退几秒，防听漏（安卓设置页第 7 项）
            let rewind = Int64(LocalStore.loadPlayPrefs().resumeRewindSeconds) * 1000
            let targetMs = max(0, saved.positionMs - rewind)
            let t = CMTime(value: targetMs, timescale: 1000)
            queue.seek(to: t)
            position = min(1.0, Double(targetMs) / Double(max(saved.durationMs, 1)))
            elapsedText = fmt(targetMs)
        } else if effectivePlayback.skipIntroSec > 0 {
            // 跳过片头（每集开头常有一段片头/广告）
            let skip = CMTime(value: CMTimeValue(effectivePlayback.skipIntroSec), timescale: 1)
            queue.seek(to: skip)
            elapsedText = fmt(Int64(effectivePlayback.skipIntroSec) * 1000)
        }

        LocalStore.pushRecent(.init(
            bookUrl: currentBook?.bookUrl ?? "",
            bookTitle: currentBook?.title ?? "",
            trackId: ep.trackId,
            episodeTitle: ep.title,
            playedAt: Date(),
            sourceId: currentSourceId, episodeUrl: ep.url,
            coverUrl: currentBook?.coverUrl ?? ""))
    }

    // MARK: - item 观察（异常路径的真身）


    /// P0-01：自然播完 → 自动续下一集
    private func handleItemDidEnd() {
        guard let ep = current else { return }
        CrashLog.write("PLAY", "item ended track=\(ep.trackId) src=\(currentSourceId)")
        // 定时·按章节停：听完当前章就停，不再往下播
        if consumeSleepChapter() {
            apply(.paused)
            updateNowPlayingInfo()
            return
        }
        guard let next = nextEpisode(after: ep, forward: !effectivePlayback.reverseOrder) else {
            apply(.paused)
            updateNowPlayingInfo()
            return
        }
        playEpisode(next, book: currentBook, sourceId: currentSourceId)
    }
    
    /// 找当前集的下一集（Player 需要持有当前书的章节列表）
    private var currentEpisodes: [SharedBridge.EpisodeRow] = []
    
    /// 方向由倒序播放决定：forward=false 时「下一集」其实是上一集
    private func nextEpisode(after ep: SharedBridge.EpisodeRow, forward: Bool = true) -> SharedBridge.EpisodeRow? {
        guard let idx = currentEpisodes.firstIndex(where: { $0.trackId == ep.trackId }) else { return nil }
        let nextIdx = forward ? idx + 1 : idx - 1
        guard nextIdx >= 0, nextIdx < currentEpisodes.count else { return nil }
        return currentEpisodes[nextIdx]
    }

    private func attachItem(_ item: AVPlayerItem) {
        observedItem = item
        // ① status：AVPlayerItem 自己会上报 .failed（网络错误、解码失败、404 的 4xx 响应），
        //    但原实现没有任何观察者，failed 就永远没人看 → 界面停在 loading/playing
        itemObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            Task { @MainActor in self?.handleStatus(it) }
        }
        
        // P0-01：自然播完监听（续章）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemDidEnd() }
        }
        // ② 播到结尾失败：起了播但中途断了（CDN 403、重定向到 HTML 错误页、断网）
        //    此时 status 已是 readyToPlay，只有这条通知能拿到 var error
        let n = NotificationCenter.default
        itemNotificationTokens.append(n.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.handleFailedToEnd(e) }
        })
        // ③ 卡顿：弱网/断网时 AVPlayer 不报错，只是卡住。给明确的「缓冲中」而不是假装在播
        itemNotificationTokens.append(n.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStalled() }
        })
    }

    private func detachItem() {
        itemObservation?.invalidate()
        itemObservation = nil
        let n = NotificationCenter.default
        for t in itemNotificationTokens { n.removeObserver(t) }
        itemNotificationTokens.removeAll()
        removeItemTimeObserver()
        observedItem = nil
    }

    private func handleStatus(_ item: AVPlayerItem) {
        guard item === observedItem else { return }
        switch item.status {
        case .readyToPlay:
            if state == .loading { apply(.playing) }
        case .failed:
            failPlayback(Self.describe(item.error))
        default:
            break
        }
    }

    private func handleFailedToEnd(_ error: Error?) {
        failPlayback(Self.describe(error))
    }

    private func handleStalled() {
        guard state == .playing else { return }
        errorText = nil
        apply(.loading)            // playing → loading 合法：显示「正在缓冲」
        // 2 秒没恢复就走 .error，不让用户对着死界面等
        let gen = requestGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard gen == self.requestGeneration, self.state == .loading else { return }
            if let it = self.observedItem, it.isPlaybackLikelyToKeepUp {
                self.apply(.playing)
                return
            }
            self.failPlayback("网络中断，播放卡住了")
        }
    }

    /// AVFoundation 的 NSURLError 原文 → 人话。原文太长，用户看不懂也不该看。
    private static func describe(_ error: Error?) -> String {
        guard let error = error else { return "音频无法播放（上游没给原因）" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时（网络太慢或源站挂了）"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "连不上源站服务器"
            case NSURLErrorNetworkConnectionLost: return "网络中断，播放已停止"
            case NSURLErrorNotConnectedToInternet: return "当前没有网络"
            case NSURLErrorSecureConnectionFailed: return "HTTPS 证书不被信任"
            case NSURLErrorCancelled: return "播放请求被取消"
            default: break
            }
        }
        let desc = ns.localizedDescription
        return desc.isEmpty ? "音频无法播放" : ("音频无法播放：" + desc)
    }

    // MARK: - 前后台 / 生命周期

    private func wireLifecycle() {
        let n = NotificationCenter.default
        n.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                self.saveProgress(force: true)     // 进后台：系统随时可能挂起，先落地
            }
        }
        n.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                self.saveProgress(force: true)   // 下拉通知中心/来电弹窗都可能触发，必须先落地
            }
        }
        n.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                // 后台期间 audio session 可能被系统回收（别的 App 抢过焦点），
                // 回前台若仍在播放就重新激活+确认 play()，避免「界面在播但没声音」
                if self.state == .playing || self.state == .paused {
                    BackgroundSession.activateForPlayback(force: true)
                    if self.state == .playing { self.queue.play() }
                }
            }
        }
        n.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive else { return }
                self.saveProgress(force: true)
            }
        }
    }

    func pause() {
        queue.pause()
        saveProgress(force: true)
        // playing→paused；loading（正在取地址/缓冲）→paused 也合法；
        // error 态收到远程 pause（比如拔耳机时本来就失败）不动状态，免得把错误界面顶掉
        if state == .playing || state == .loading { apply(.paused) }
        updateNowPlayingInfo()
    }

    func resume() {
        guard current != nil else { return }
        if state == .error { retry(); return }
        guard queue.currentItem != nil else {
            // 队列空了（播放失败后被清空）：重新取地址，别装着播
            retry()
            return
        }
        BackgroundSession.activateForPlayback(force: state != .playing)
        queue.play()
        apply(.playing)
        updateNowPlayingInfo()
    }

    func stop() {
        saveProgress(force: true)
        requestGeneration &+= 1            // 让在途的取地址响应作废
        requestingEpisode = false
        resetPipeline()
        clearNowPlaying()
        if state != .stopped { apply(.stopped) }
        position = 0
        elapsedText = "0:00"
        durationText = "0:00"
        errorText = nil
        canRetry = false
    }

    /// 按偏好秒数快进/快退（对应安卓「快进快退秒数」，默认 10 秒）
    func skip(_ forward: Bool) {
        defer { updateNowPlayingInfo() }
        guard let item = queue.currentItem, item.duration.isNumeric else { return }
        let secs = Double(LocalStore.loadPlayPrefs().seekSeconds)
        let target = item.currentTime().seconds + (forward ? secs : -secs)
        let clamped = max(0, min(item.duration.seconds, target))
        queue.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        saveProgress(force: true)
    }

    func seek(toFraction f: Double) {
        guard let item = queue.currentItem else { return }
        let d = item.duration
        guard d.isNumeric else { return }
        let secs = d.seconds * max(0, min(1, f))
        queue.seek(to: CMTime(seconds: secs, preferredTimescale: 600))
        saveProgress(force: true)          // 用户拖动后立刻落，避免退出时回到旧位置
    }

    /// 打断恢复：interruption .shouldResume 到来时，队列里有章节才续播
    func resumeAfterInterruption() {
        guard !queue.items().isEmpty else { return }
        BackgroundSession.activateForPlayback(force: true)
        queue.play()
        apply(.playing)
        updateNowPlayingInfo()
    }

    /// 拔耳机 / 蓝牙断开：暂停并落进度（由 BackgroundSession 路由过来）
    func pauseForRouteChange() {
        guard state == .playing || state == .loading else { return }
        pause()
    }

    // MARK: - 进度

    /// 实例级 1Hz observer：全 App 只注册一次，init 里调，换章不动它。
    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = queue.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self, self.isLive else { return }
            let d = self.queue.currentItem?.duration
            if let d, d.isNumeric, d.seconds > 0 {
                self.position = min(1.0, max(0, t.seconds / d.seconds))
                self.elapsedText = self.fmt(Int64(t.seconds * 1000))
                self.durationText = self.fmt(Int64(d.seconds * 1000))
            }
            self.saveProgress(force: false)
        }
    }

    /// 换章时 AVQueuePlayer 会把实例 observer 摘掉（Apple 已知行为），
    /// 原实现只装了实例 observer，切章的瞬间开始进度条就冻住。
    /// 补一个绑在 item 上的 ticker 兜底：同一 item 只装一次，detachItem 统一摘。
    private func installItemTimeObserver() {
        removeItemTimeObserver()
        installTimeObserver()              // 实例 observer 若已被摘，这里补回
        guard let item = observedItem else { return }
        // AVPlayerItem 没有 addPeriodicTimeObserver，只能向 AVPlayer 注册；
        // 用 observedItem 校验回调仍属于当前 item，换章后旧回调自动忽略。
        itemObserver = queue.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            Task { @MainActor in
                guard let self, self.isLive, self.observedItem === item else { return }
                let d = item.duration
                if d.isNumeric, d.seconds > 0 {
                    self.position = min(1.0, max(0, t.seconds / d.seconds))
                    self.elapsedText = self.fmt(Int64(t.seconds * 1000))
                    // 跳过片尾：到达「总长 - skipOutro」就主动结束本集
                    let outro = Double(self.effectivePlayback.skipOutroSec)
                    if outro > 0, d.seconds - t.seconds <= outro, d.seconds - t.seconds > 0 {
                        self.handleItemDidEnd()
                        return
                    }
                }
                self.saveProgress(force: false)
            }
        }
    }

    private func removeItemTimeObserver() {
        if let t = itemObserver {
            queue.removeTimeObserver(t)
        }
        itemObserver = nil
    }

    /// 队列整体清空后（stop / 播放失败后重来），AVQueuePlayer 会自行摘掉实例 observer；
    /// dealloc 时再 removeTimeObserver 老 token 可能抛异常 —— 这里用防御式包一层。
    private func safeRemoveInstanceObserver() {
        guard let t = timeObserver else { return }
        defer { timeObserver = nil }
        queue.removeTimeObserver(t)
    }

    /// 失败后重来：清队列 → 重新装 observation → 重新装秒表。
    /// 这是「点下一集能不能救回来」的关键路径，原来这里没有对应处理，
    /// error 之后秒表和 item 观察全断，再点一集只有声音没进度。
    private func resetPipeline() {
        detachItem()
        queue.removeAllItems()
        installTimeObserver()
    }

    private func saveProgress(force: Bool) {
        guard current != nil, currentBook != nil, queue.currentItem != nil else { return }
        guard !requestingEpisode else { return }   // 地址还没回来，currentTime 是旧集的
        let nowMs = Int64(queue.currentTime().seconds * 1000)
        guard nowMs > 0 else { return }
        // 强制保存不受 5 秒窗口约束（暂停/切章/退出/拖动必须落）
        if !force, abs(nowMs - lastSavedMs) < 5_000 { return }
        lastSavedMs = nowMs
        let durMs: Int64 = {
            if let d = queue.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                return Int64(d.seconds * 1000)
            }
            return current?.durationMs ?? 0
        }()
        guard let ep = current, let b = currentBook else { return }
        LocalStore.saveProgress(.init(
            bookUrl: b.bookUrl, title: b.title,
            trackId: ep.trackId, episodeTitle: ep.title,
            positionMs: nowMs, durationMs: durMs, updatedAt: Date(),
            sourceId: currentSourceId, albumId: b.albumId))
    }

    private func fmt(_ ms: Int64) -> String {
        let s = ms / 1000
        if s >= 3600 { return String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60) }
        return String(format: "%d:%02d", s/60, s%60)
    }
}
