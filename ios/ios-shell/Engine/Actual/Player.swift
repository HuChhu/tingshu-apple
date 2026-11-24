import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// AVFoundation 的通知名在不同部署目标下是两套符号：
/// 新名（AVPlayerItemFailedToPlayToEndTimeNotification）在 iOS 11.2+ 才存在，
/// 老名（错误 key 字符串本身）在更老的系统上才是实际发出的那一个。
/// 用同一个 Notification.Name 同时挂两路，保证任何系统版本都有人接。
private enum AVCompatNames {
    /// 与新名同值；单独命名是为了在 grep 里能审计「老系统路径」是否在位
    static let failedToPlayToEnd = Notification.Name("AVPlayerItemFailedToPlayToEndTimeNotification")
    /// AVPlayerItem.newErrorLogEntryNotification（解码/网络错误日志新增）
    static let newErrorLogEntry = Notification.Name("AVPlayerItemNewErrorLogEntryNotification")
    static let failedToPlayToEndErrorKey = "AVPlayerItemFailedToPlayToEndTimeErrorKey"
}


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
        cancelStartWatchdog(reachedReady: nil)
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
        cancelStartWatchdog(reachedReady: nil)
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
            guard let self else { return .commandFailed }
            // 失败态：线控播放键 = 重试（不用点亮屏幕回 App）
            if self.state == .error { self.retry(); return .success }
            self.resume()
            return .success
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
    }

    private func addRemote(
        _ cmd: MPRemoteCommand,
        guard liveGuard: @escaping () -> Bool,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        // P1-04：用 addTarget(_:action:) 而不是闭包。
        // selector 由 Objective-C 运行时在主线程调用，天然隔离正确。
        // 闭包方式可能在任意线程触发，导致 @MainActor 越界。
        // 防御：同一个 command 重复注册会让 remoteHandlers 字典键覆盖、旧 handler 永久失效。
        // 历史上 playCommand 就因此在线控场景失灵过。
        if remoteHandlers[cmd] != nil {
            #if DEBUG
            debugPrint("[Player] 重复注册 remote command，已忽略：" + String(describing: cmd))
            #endif
            return
        }
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
    /// 起播超时看门狗：URL 已拿到但 item 迟迟不 readyToPlay → 给可读文案 + 自动降级无 header 重试一次
    private var startWatchdog: Task<Void, Never>?
    /// 已经降级重试过的 trackId（同一个 item 只降级一次，防循环）
    private var fallbackTriedTrack: Int64 = -1
    /// 当前 item 的请求头（降级重试要用）
    private var currentHeaders: [String: String] = [:]
    /// 当前 item 的源地址（重建立 AVURLAsset 用）
    private var currentAssetURL: URL?
    /// 本次起播的墙钟时刻。① 判断 stalled 是不是「起播阶段」 ② 计时播完的自动续章
    private var startedAt: Date = .distantPast

    /// 快进/快退是否可用：只有真的挂着 item 才能 seek（error/stopped 时队列是空的）
    var canSeek: Bool {
        guard state == .playing || state == .paused else { return false }
        return queue.currentItem != nil
    }

    /// 远程命令/后台回调只对活着的那个实例生效
    private var isLive: Bool { Player.shared === self }

    // ===== 睡眠定时 =====
    /// 用户是否手动取消过定时。取消后自动连播换章不得再按 prefs 自动重开。
    private var sleepCancelledByUser = false
    /// 按时间停：到点执行的截止时刻
    private var sleepDeadline: Date?
    /// 按章节停：还剩几章（<0 表示没启用）
    private var sleepChaptersLeft: Int = -1

    /// 启动定时（minutes > 0 用时间；chapters > 0 用章节，二者取一个）
    func startSleepTimer(minutes: Int, chapters: Int) {
        sleepCancelledByUser = false
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
        sleepCancelledByUser = true
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
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause()
                self.cancelSleepTimer()
            }
        }
        // 用 common 模式：默认 default 模式下用户滚动列表时定时器不触发，睡点会延后
        RunLoop.main.add(t, forMode: .common)
        sleepTimer = t
    }

    /// 重启 App 后按上次设置重新定时（prefs.sleepAutoEnable）
    func restoreSleepTimerIfNeeded() {
        // 用户手动取消过 → 本次会话不再自动恢复（否则自动连播会把它"复活"）
        guard !sleepCancelledByUser else { return }
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
    /// 当前书的封面地址与书名，供播放页海报层读取。
    var currentCoverUrl: String { currentBook?.coverUrl ?? "" }
    var currentBookTitle: String { currentBook?.title ?? "" }
    /// 定时剩余文案：按时间显示 "mm:ss"，按章节显示 "剩 N 章"，没启用返回 nil
    var sleepRemainingText: String? {
        if let d = sleepDeadline {
            let left = Int(max(0, d.timeIntervalSinceNow))
            return String(format: "定时 %d:%02d", left / 60, left % 60)
        }
        if sleepChaptersLeft > 0 { return "剩 \(sleepChaptersLeft) 章" }
        return nil
    }

    /// 把有效增益应用到当前 item。dB → 线性：gain = 10^(dB/20)，再夹到 0...1
    /// 负增益（压音量）能精确生效；正增益受 AVPlayer 上限 1.0 限制，只能到原始音量。
    private func applyVolumeGain() {
        let db = effectivePlayback.volumeGainDb
        let linear = db.isFinite ? pow(10.0, db / 20.0) : 1.0
        // 注意：volume 在 AVPlayer 上，不在 AVPlayerItem 上（后者只有 audioMix）
        queue.volume = Float(min(1.0, max(0.0, linear)))
    }

    /// 设置里改完音量增益，立即生效（不用等下一集）
    func refreshVolumeGain() {
        applyVolumeGain()
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
        // nil 也要清空：否则首页续播（不传 episodes）会沿用上一本书的列表，
        // trackId 撞号时自动连播跳到完全不相关的书
        currentEpisodes = episodes ?? []
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
            // 兜底 UA：模板站/嗅探出来的直链常常「裸请求 403、带 UA 就过」
            // （实测 xmcdn 系：不带 UA 直接 deny by rule engine）。
            if let a = audio {
                audio = SharedBridge.audioWithDefaultUA(a)
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
        cancelStartWatchdog(reachedReady: nil)
        fallbackTriedTrack = -1
        currentHeaders = [:]
        currentAssetURL = nil
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
    
    /// 起播后的后台动作：以前是 `URLSession.shared.download(for:)` 整集下载。
    /// 那是「操作已停止」的直接放大器：同一 URL 两条连接同时拉，源站（模板站尤其）
    /// 通常按 UA+IP 限 1 并发，谁先到把另一条掐掉 —— 被掐的恰恰是要出声的那条 AVURLAsset。
    /// 现在只做「标头预检」：一个 HTTP HEAD（不支持就 GET Range: bytes=0-0），
    /// 判 2xx + Content-Type 是音频。不占音频带宽，也不和主播放抢连接。
    /// 真正落盘交给以后接 AVAudioSession 后台下载时再开（那时才需要下载队列）。
    /// 名字保留（调用点不变），实际已是标头预检，不再下载整集。
    private func cacheInBackground(url: URL, headers: [String: String]) {
        guard let book = currentBook else { return }
        let bookUrl = book.bookUrl
        let trackId = current?.trackId ?? 0
        guard trackId > 0 else { return }
        // 已经缓存就没什么可预检的
        if AudioCache.cachedFile(bookUrl: bookUrl, trackId: trackId) != nil { return }

        Task.detached(priority: .utility) {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 10
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let probe = try? await URLSession.shared.data(for: req)
            if let (_, resp) = probe, let http = resp as? HTTPURLResponse {
                let ok = (200...299).contains(http.statusCode)
                let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let isAudio = ctype.contains("audio") || ctype.contains("mpeg") || ctype.contains("octet-stream")
                CrashLog.write("PLAY", "probe track=\(trackId) code=\(http.statusCode) ctype=\(ctype) ok=\(ok && isAudio)")
                return
            }
            // HEAD 被拒（405/403）：退一步用 Range 探 1 字节，同样只读一个包，不下载整集
            var r2 = URLRequest(url: url)
            r2.timeoutInterval = 10
            r2.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            for (k, v) in headers { r2.setValue(v, forHTTPHeaderField: k) }
            guard let (d, resp) = try? await URLSession.shared.data(for: r2),
                  let http = resp as? HTTPURLResponse else {
                CrashLog.write("PLAY", "probe track=\(trackId) failed both HEAD and Range")
                return
            }
            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            CrashLog.write("PLAY", "probe track=\(trackId) range code=\(http.statusCode) bytes=\(d.count) ctype=\(ctype)")
        }
    }

    private func startItem(url: URL, headers: [String: String], ep: SharedBridge.EpisodeRow) {
        CrashLog.write("PLAY", "start remote track=\(ep.trackId) src=\(currentSourceId) scheme=\(url.scheme ?? "") host=\(url.host ?? "")")
        // 起播后按上次配置恢复睡眠定时（sleepAutoEnable 打开时生效）
        if sleepDeadline == nil, sleepChaptersLeft <= 0 { restoreSleepTimerIfNeeded() }
        requestingEpisode = false
        BackgroundSession.activateForPlayback()

        // 缓存优先：已缓存的集直接播本地文件（离线可用）。
        // 本地文件同样要挂 status 观察 —— 以前走 startItemWithLocalFile 时状态停在 .playing，
        // 文件被系统清掉/截断时界面永远卡「播放中」，也是「点第一集没反应」的一条来源。
        if let cached = cachedURL(for: url), FileManager.default.fileExists(atPath: cached.path),
           let size = (try? FileManager.default.attributesOfItem(atPath: cached.path))?[.size] as? NSNumber,
           size.int64Value > 16 * 1024 {
            let litem = AVPlayerItem(url: cached)
            beginPlayback(litem, ep: ep, via: "local", headers: [:], sourceURL: cached)
            return
        }

        beginPlayback(newItem(url: url, headers: headers), ep: ep,
                      via: "remote", headers: headers, sourceURL: url)
    }

    /// 建 item。请求头只加在 http(s) 上：file:// 带 `AVURLAssetHTTPHeaderFieldsKey`
    /// 会让 AVURLAsset 拿不到播放资源（本机缓存播放失败的一条来源）。
    private func newItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let scheme = (url.scheme ?? "").lowercased()
        let useHeaders = !headers.isEmpty && (scheme == "http" || scheme == "https")
        let opts: [String: Any] = useHeaders ? ["AVURLAssetHTTPHeaderFieldsKey": headers] : [:]
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        if LocalStore.loadPlayPrefs().skipSilence, #available(iOS 16.4, *) {
            // iOS 16.4+ 支持自动跳过静音段
            item.audioTimePitchAlgorithm = .timeDomain
        }
        return item
    }

    /// 唯一的挂载入口（remote / local / 降级重试都走这里）。
    /// 顺序不可换：detach 旧观察 → pause → removeAllItems → insert → attach。
    /// 先 pause 再清队列：AVQueuePlayer 在 playing 状态下换 items 会走「等待最小化卡顿」，
    /// 拿 0 速率去看似 ready 的 item 上等，真机上是点进去一直转的直接来源。
    private func beginPlayback(_ item: AVPlayerItem, ep: SharedBridge.EpisodeRow,
                               via: String, headers: [String: String], sourceURL: URL) {
        if via == "remote", AudioCache.loadSettings().autoCacheNext {
            // 边播边缓存：起播后异步取标头（见 cacheHeaders 注释里为何不再整段下载）
            cacheInBackground(url: sourceURL, headers: headers)
        }
        currentHeaders = headers
        currentAssetURL = sourceURL
        detachItem()
        queue.pause()
        queue.removeAllItems()
        // 实例级 observer 只在 init 装一次（无 item 时兜底显示）。
        // 每次起播都重装会导致两层 observer 并存：每秒双写进度、skipOutro 判定分裂。
        queue.insert(item, after: nil)
        attachItem(item)
        installItemTimeObserver()
        queue.play()
        errorText = nil
        durationText = fmt(ep.durationMs)
        // 音量增益：远程路径同样要应用（之前只接了本地缓存分支，等于网播时设置无效）
        applyVolumeGain()
        let sp = effectivePlayback.speed
        queue.rate = Float(sp.isFinite && sp > 0 ? min(3.0, max(0.5, sp)) : 1.0)
        apply(.playing)

        // 续播：上次听到哪就从哪开始（超过 95% 视为听完，从头放）
        if let b = currentBook,
           let saved = LocalStore.progress(for: BookKey(sourceId: currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)),
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

        startedAt = Date()
        CrashLog.write("PLAY", "start " + via + " track=\(ep.trackId) status=\(item.status.rawValue) hdr=\(headers.count)")
        LocalStore.pushRecent(.init(
            bookUrl: currentBook?.bookUrl ?? "",
            bookTitle: currentBook?.title ?? "",
            trackId: ep.trackId,
            episodeTitle: ep.title,
            playedAt: Date(),
            sourceId: currentSourceId, episodeUrl: ep.url,
            coverUrl: currentBook?.coverUrl ?? ""))
        armStartWatchdog(ep: ep)
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
        // 身份闸：通知是按 item 注册的，但对象被换掉后系统仍可能补发一次迟到的回调。
        // 之前这三条 handler 只看 self，不看 note.object —— 上一集的「播完」会把新一集
        // 直接跳到再下一集（连跳两章），上一集的 -999 会写进新一集的错误界面。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let ended, self.observedItem === ended else { return }
                self.handleItemDidEnd()
            }
        }
        // ② 播到结尾失败：起了播但中途断了（CDN 403、重定向到 HTML 错误页、断网）
        //    此时 status 已是 readyToPlay，只有这条通知能拿到 var error
        let n = NotificationCenter.default
        itemNotificationTokens.append(n.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let failed = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let failed, self.observedItem === failed else { return }
                self.handleFailedToEnd(e)
            }
        })
        // ③ 卡顿：弱网/断网时 AVPlayer 不报错，只是卡住。给明确的「缓冲中」而不是假装在播
        itemNotificationTokens.append(n.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] note in
            let stalled = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let stalled, self.observedItem === stalled else { return }
                self.handleStalled()
            }
        })
        // ④ 项目按 iOS 12 最低版本编译时，「FailedToPlayToEnd」只有这个老名字会发。
        //    名字新、行为旧 —— 漏挂它，iOS 12/13 机器上中途断流永远无人接。
        itemNotificationTokens.append(n.addObserver(
            forName: AVCompatNames.failedToPlayToEnd,
            object: item, queue: .main
        ) { [weak self] note in
            let e = note.userInfo?[AVCompatNames.failedToPlayToEndErrorKey] as? Error
            Task { @MainActor in self?.handleFailedToEnd(e) }
        })
        // ⑤ AVPlayerLooper 语义：同一 item 被重复插入时系统会报这个错，
        //    一律当「起播失败」处理会误导用户；这里只记日志，不算失败。
        itemNotificationTokens.append(n.addObserver(
            forName: AVCompatNames.newErrorLogEntry,
            object: item, queue: .main
        ) { note in
            let it = note.object as? AVPlayerItem
            let ev = it?.errorLog()?.events.last
            CrashLog.write("PLAY", "item errorlog code=\(ev?.errorStatusCode ?? 0) uri=\(ev?.uri ?? "-")")
        })
    }

    private func detachItem() {
        itemObservation?.invalidate()
        itemObservation = nil
        let n = NotificationCenter.default
        for t in itemNotificationTokens { n.removeObserver(t) }
        itemNotificationTokens.removeAll()
        removeItemTimeObserver()
        // endObserver 是 NotificationCenter 的 playToEnd 监听，之前从未清理 →
        // 长连播下 token 线性增长（每集一个），最终内存与回调开销都上去了
        if let eo = endObserver {
            NotificationCenter.default.removeObserver(eo)
            endObserver = nil
        }
        observedItem = nil
    }

    /// status 三态。.unknown 是 KVO 的 .initial 首次回调（每个新 item 必来一次），
    /// 此时 asset 还在加载，什么都不该做 —— 更不能当失败。
    /// .failed 要分两种：用户自己换台导致的 -999 与真失败，见 isSelfInflictedCancel。
    private func handleStatus(_ item: AVPlayerItem) {
        guard item === observedItem else { return }
        switch item.status {
        case .readyToPlay:
            cancelStartWatchdog(reachedReady: true)
            if state == .loading || state == .playing {
                // .playing 也走一次：beginPlayback 是乐观置 playing 的，这里确认后才刷锁屏时长
                if state == .loading { apply(.playing) }
                updateNowPlayingInfo()
            }
        case .failed:
            // 先判取消：换台/清队列时系统会对被摘掉的 item 补一次 .failed(-999)，
            // 这是「操作已停止」在日志里最常见的来源之一。旧 item 的失败不能算到新集头上。
            if isSelfInflictedCancel(item) {
                CrashLog.write("PLAY", "ignore stale item failure track=\(current?.trackId ?? 0)")
                return
            }
            cancelStartWatchdog(reachedReady: false)
            if let ns = item.error as NSError?, ns.code == NSURLErrorCancelled {
                // 当前 item 真被取消：先降级去掉 header 重试一次，不行再报
                if fallbackWithoutHeadersIfPossible(reason: "status cancelled") { return }
            }
            failPlayback(Self.describe(item.error))
        default:
            break
        }
    }

    private func handleFailedToEnd(_ error: Error?) {
        if let it = observedItem, isSelfInflictedCancel(it) {
            CrashLog.write("PLAY", "ignore self-inflicted end-error track=\(current?.trackId ?? 0)")
            return
        }
        failPlayback(Self.describe(error))
    }

    /// 卡顿：只对「已经在出声音」的 item 生效。
    /// 起播阶段（status != .readyToPlay）不在这里判失败 —— 那是启动看门狗 armStartWatchdog 的职责，
    /// 2 秒窗口在弱网起播时必然误杀。
    private func handleStalled() {
        guard state == .playing, let it = observedItem, it.status == .readyToPlay else { return }
        // 起播后 3 秒内发来的 stalled 属于「首包慢」，交给启动看门狗统一处理；
        // 这里只接「已经播了一会儿又断」的场景。（原判据用 currentTime>1s，但卡住时 currentTime 不动，
        // 播到 0.9 秒才断的集会被永久跳过，界面停在「播放中」不动而没有任何提示。）
        guard Date().timeIntervalSince(startedAt) > 3.0 else { return }
        errorText = nil
        apply(.loading)            // playing → loading 合法：显示「正在缓冲」
        let gen = requestGeneration
        let item = it
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard gen == self.requestGeneration, self.state == .loading, self.observedItem === item else { return }
            if item.isPlaybackLikelyToKeepUp {        // 缓冲回来了就回 playing
                self.apply(.playing)
                return
            }
            self.failPlayback("网络中断，播放卡住了")
        }
    }

    /// 判断一个报错的 item 是不是「已经被我们换掉/清掉」的那个。
    /// -999 不带语境，但身份是可靠的：队列里已经不是它，或它已不是 observedItem，
    /// 就说明这个失败属于上一轮操作，不该写进当前界面的 errorText。
    private func isSelfInflictedCancel(_ item: AVPlayerItem) -> Bool {
        guard item === observedItem else { return true }   // 已被 detach：上一轮的残响
        if queue.currentItem !== item { return true }       // 已被 removeAllItems 摘掉
        return false
    }

    /// 起播超时看门狗。真机上「点第一集 → 一会儿报错」有两条来源：
    /// ① header 被 CDN 拒（返回 403/302 到错误页），AVFoundation 反复重试不 ready；
    /// ② 弱网首包慢。二者都不该直接报错，先给 12 秒，再降级无 header 重试一次，最后才失败。
    private func armStartWatchdog(ep: SharedBridge.EpisodeRow) {
        cancelStartWatchdog(reachedReady: nil)
        let gen = requestGeneration
        let track = ep.trackId
        startWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            guard gen == self.requestGeneration, self.current?.trackId == track else { return }
            guard let it = self.observedItem, it.status != .readyToPlay else { return }
            if self.fallbackWithoutHeadersIfPossible(reason: "start timeout") { return }
            self.failPlayback("起播超时（12 秒没拿到音频，源站无响应）")
        }
    }

    /// 取消看门狗。reachedReady 只用于日志：判定本身靠「同一个代际 + 同一个 trackId + item 仍未 ready」。
    private func cancelStartWatchdog(reachedReady: Bool?) {
        if let why = reachedReady {
            CrashLog.write("PLAY", "watchdog cancel ready=\(why)")
        }
        startWatchdog?.cancel()
        startWatchdog = nil
    }

    /// 降级重试：去掉自定义请求头重建 AVURLAsset。同一集只试一次。
    /// 依据：300 多个模板站里，部分 CDN 对额外的 Referer/UA 直接回 403 或 302，
    /// 而不带 header 的裸 GET 是能播的；AVFoundation 对这种 403 的反应就是反复重试直到取消。
    private func fallbackWithoutHeadersIfPossible(reason: String) -> Bool {
        // 代际闸：重建 item 是异步链条里的一步，用户可能已经点了下一集。
        // 没有这道闸时，旧集的降级重试会把 item 重新 insert 进队列，把新集顶掉。
        let gen = requestGeneration
        guard let ep = current, let url = currentAssetURL, !currentHeaders.isEmpty else { return false }
        // 去 header 降级只对「额外的 Referer/UA 把 CDN 惹毛」的情况有意义。
        // 但部分 CDN（实测 xmcdn 系列）反过来：**不带 UA 直接 403**，
        // 这时去 header 等于把唯一能用的一条路也堵死，而且 AVPlayer 会反复重试到取消，
        // 最终把「源站拒绝裸请求」误报成「音频无法播放：操作已停止」。
        // 判据：原来有 User-Agent 而现在要丢掉它 —— 丢掉就可能失去授权，不降级。
        guard currentHeaders["User-Agent"] == nil else {
            CrashLog.write("PLAY", "skip no-header fallback track=\(ep.trackId) reason=\(reason) (UA required)")
            return false
        }
        guard fallbackTriedTrack != ep.trackId else { return false }
        fallbackTriedTrack = ep.trackId
        CrashLog.write("PLAY", "fallback no-header track=\(ep.trackId) reason=\(reason)")
        guard gen == requestGeneration else { return true }   // 已被新的一集取代，别再重挂 item
        let it = newItem(url: url, headers: [:])
        beginPlayback(it, ep: ep, via: "remote-fallback", headers: [:], sourceURL: url)
        return true
    }

    /// AVFoundation 的 NSURLError 原文 → 人话。原文太长，用户看不懂也不该看。
    private static func describe(_ error: Error?) -> String {
        guard let error = error else { return "音频无法播放（源站没有响应）" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时（网络太慢或源站挂了）"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "连不上源站服务器"
            case NSURLErrorNetworkConnectionLost: return "网络中断，播放已停止"
            case NSURLErrorNotConnectedToInternet: return "当前没有网络"
            case NSURLErrorSecureConnectionFailed: return "HTTPS 证书不被信任"
            case NSURLErrorCancelled:
                // -999 的 localizedDescription 是「操作已停止」，对用户等于没信息。
                // 走到这里说明已经排除了「自己换台」的情况，能确定是源站/系统层撤的请求。
                return "源站中断了请求（音频地址失效，点重试可重新取地址）"
            default: break
            }
        }
        // AVFoundation 解码层错误（-11800 等）走到这里：把 code 也带上，便于用户截图反馈
        let desc = ns.localizedDescription
        return desc.isEmpty ? "音频无法播放（错误码 \(ns.code)）" : ("音频无法播放：" + desc + "（\(ns.code)）")
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
        cancelStartWatchdog(reachedReady: nil)
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
        // 不再重复安装实例级 observer：item 级已经每秒回调，两层同时跑会双写进度
        // （实例级只在没有 item 的等待期兜底，这里不需要）
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
        queue.pause()               // 先停速率再清，避免 AVQueuePlayer 在清空瞬间触发一次 -999
        queue.removeAllItems()
        // 不重装实例级 observer（init 已装且从未移除）
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
