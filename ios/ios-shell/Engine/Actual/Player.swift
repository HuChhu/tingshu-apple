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


/// AVURLAsset 走自定义 scheme 时，由这个 delegate 真正发请求并回填数据。
///
/// 为什么必须换成 `dshmedia://` 这种自定义 scheme：
/// AVFoundation 只在「系统网络栈认不出这个 scheme」时才调 resourceLoader。
/// 原样传 https:// 的话 delegate 永远不会被调用，挂与不挂没区别。
///
/// 为什么必须自己发请求：
/// ① `AVURLAssetHTTPHeaderFieldsKey` 是非公开 key，iOS 16+ 起不再稳定生效；
/// ② 就算生效，302 跳转到真实 CDN 后 AVFoundation **不再带 header**，
///    于是第二跳 403 → 永远不 readyToPlay → 起播超时（本次故障的直接成因）。
/// 自己发请求时我们要手动跟随 302 并重新带上 header（`viaRedirect: true`）。
///
/// 线程：`setDelegate(_, queue: .main)` 让 resourceLoader 的请求同步跑在主队列；
/// URLSession 也用 `delegateQueue: .main`，两边的回调因此落在同一个执行域。
/// Apple 文档明确：resourceLoader 的请求「在你的队列上同步处理」，URLSession 的
/// completion「在你的 operation queue 上调度」—— 都传主队列入即同域。
/// AVAssetResourceLoadingRequest 不是线程安全的，跨线程回填会随机崩在
/// `-[AVAssetResourceLoadingDataRequest respondWithData:]`。
private final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    /// 自定义 scheme。`dshmedia` 对应 http，`dshmedias` 对应 https。
    static let scheme = "dshmedia"
    /// URL 里的双斜杠（转义写法，避开注释剥离器）
    static let sep: String = "//"

    private let headers: [String: String]
    /// var 而不是 let：init 里要先建一个占位 session，super.init() 之后才能用 self 当 delegate。
    /// 回填没有独立队列：resourceLoader 与 URLSession 都落在主队列，见 init 注释。
    private var session: URLSession

    init(headers: [String: String]) {
        self.headers = headers
        // delegateQueue 必须给 .main：completionHandler 默认跑在 session 自己的后台队列，
        // 那里拿到 AVAssetResourceLoadingRequest 再 respond 就是跨线程 —— 真机随机崩。
        // 而 setDelegate(_, queue: .main) 也已指定主队列，两边同域后才安全。
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 单 host 连接压到 2：模板站普遍限并发，开太多会被风控
        cfg.httpMaximumConnectionsPerHost = 2
        // URLSession 必须挂 self 做 delegate：流式回填靠 didReceive response / didReceive data。
        // delegateQueue 用 .main，和 setDelegate(_, queue: .main) 同域 ——
        // AVAssetResourceLoadingRequest 不是线程安全的，跨线程回填会随机崩。
        // 先建一个空 session 占位，super.init() 之后换成本类做 delegate
        // （Swift 要求 super.init() 前不能用 self）。
        self.session = URLSession(configuration: cfg, delegate: nil, delegateQueue: .main)
        super.init()
        self.session.invalidateAndCancel()
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func tearDown() {
        session.invalidateAndCancel()
    }

    // MARK: scheme 互转

    static func isWrapped(_ u: URL) -> Bool {
        let sch = u.scheme ?? ""
        return sch.hasPrefix(scheme)
    }

    /// http(s)://host/path → dshmedia://host/path（https 走 dshmedias://）。
    /// 系统网络栈不认识 dshmedia(s)，才会把请求交给 resourceLoader。
    static func wrap(_ u: URL) -> URL? {
        let s = (u.scheme ?? "").lowercased()
        guard s == "http" || s == "https" else { return nil }
        guard let marker = u.absoluteString.range(of: Self.sep) else { return nil }
        let tail = String(u.absoluteString[marker.lowerBound...])
        let prefix = (s == "https") ? "dshmedias" : "dshmedia"
        return URL(string: prefix + ":" + tail)
    }

    /// dshmedia(s)://host/path → http(s)://host/path
    static func unwrap(_ u: URL) -> URL? {
        let s = (u.scheme ?? "").lowercased()
        guard s == "dshmedia" || s == "dshmedias" else { return nil }
        guard let marker = u.absoluteString.range(of: Self.sep) else { return nil }
        let tail = String(u.absoluteString[marker.lowerBound...])
        let prefix = (s == "dshmedias") ? "https" : "http"
        return URL(string: prefix + ":" + tail)
    }

    // MARK: AVAssetResourceLoaderDelegate

    /// 登记表：loadingRequest → 它的底层 dataTask。
    /// 用途只有一个：didCancel 时真正把网络请求掐掉。没有它，用户快速切集会留下
    /// 一堆还在下载的 task，把源站并发占满（模板站限 1~2 并发），下一集就永远拿不到数据。
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let wrapped = loadingRequest.request.url, let orig = Self.unwrap(wrapped) else {
            loadingRequest.finishLoading(with: NSError(domain: "dshmedia", code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "scheme 还原失败"]))
            return false
        }
        var req = URLRequest(url: orig)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        // identity：不接受 gzip，否则 AVFoundation 拿到的 length 和实际字节对不上
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        let len = loadingRequest.dataRequest?.requestedLength ?? 0
        if loadingRequest.dataRequest == nil {
            // AVFoundation 的第一条请求是纯 content-info（dataRequest == nil）：
            // 它只想拿到「总长度 + 类型」，不想要任何音频字节。
            // 这里如果不设 Range，就会变成整集 GET —— 60MB 的集在弱网下必然把
            // 15 秒请求超时和 60 秒资源超时撞满，用户看到的就是「12 秒起播超时」。
            // 用 bytes=0-1 探两个字节：长度信息就在 Content-Range 的 /TOTAL 里。
            req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        } else if offset > 0, len > 0 {
            // 只要需要的那一段，不强求整集
            req.setValue("bytes=\(offset)-\(offset + Int64(len) - 1)", forHTTPHeaderField: "Range")
        } else if offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else if len > 0 {
            // 从头读、且只要 len 个字节：首次起播就是这条，必须带上结束位置，
            // 否则又退化成整集下载（流式能起播，但流量和内存都不该这么花）
            req.setValue("bytes=0-\(Int64(len) - 1)", forHTTPHeaderField: "Range")
        }

        // 流式：dataTask 一收到 response / data 就回填，不等整集下完。
        // 这是「12 秒不 ready」在新方案下仍会复现的根本原因：
        // 60MB 的集用 dataTask 全缓冲，弱网下 60 秒才 finishLoading，AVPlayer 永远等不到首字节。
        let task = session.dataTask(with: req)
        tasks[ObjectIdentifier(loadingRequest)] = task
        if let r = req.value(forHTTPHeaderField: "Range") {
            originalRange[ObjectIdentifier(task)] = r
        }
        pendingRequests[task.taskIdentifier] = Pending(lr: loadingRequest, base: 0, written: 0, fulfilled: false)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        guard let t = tasks.removeValue(forKey: key) else { return }
        pendingRequests.removeValue(forKey: t.taskIdentifier)
        t.cancel()                       // 必须真取消：否则切集后旧集还在后台吃带宽
        CrashLog.write("PLAY", "loader cancel task=\(t.taskIdentifier)")
    }

    /// 每个任务的状态。acc 是「字节流里已经处理到哪」，不需要缓存整段 Data。
    private struct Pending {
        let lr: AVAssetResourceLoadingRequest
        let base: Int64        // 本次响应 0 字节对应文件里的偏移（206 从 Content-Range 取，200 为 0）
        var written: Int64     // 已经向 dataRequest 写过去的字节数
        /// 已经写够 AVFoundation 要的区间，是**我们自己**主动 cancel 的。
        /// 那种情况 didCompleteWithError 会带一个 -999 进来 —— 那是取消不是失败，
        /// 必须按成功收尾，否则 item 被判 failed，界面报「请求被系统中断」，又播不了。
        var fulfilled: Bool
    }
    private var pendingRequests: [Int: Pending] = [:]

    // MARK: URLSessionDataDelegate

    /// 收到响应头：立刻回填 contentInformationRequest 并放行。
    /// 同时在这里就把 200/206 的基准偏移算好，后面切片全靠它。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var st = pendingRequests[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            st.lr.finishLoading(with: NSError(domain: NSURLErrorDomain, code: http.statusCode,
                                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            pendingRequests.removeValue(forKey: dataTask.taskIdentifier)
            tasks.removeValue(forKey: ObjectIdentifier(st.lr))
            completionHandler(.cancel)
            return
        }
        let base = Self.contentRangeStart(response)      // 200 → 0；206 → Content-Range 起点
        let httpInfo = response as? HTTPURLResponse
        let codeText = httpInfo.map { String($0.statusCode) } ?? "-"
        let mimeText = response.mimeType ?? "-"
        let crText = httpInfo?.value(forHTTPHeaderField: "Content-Range") ?? "-"
        let acrText = httpInfo?.value(forHTTPHeaderField: "Accept-Ranges") ?? "-"
        CrashLog.write("PLAY", "loader resp code=" + codeText + " mime=" + mimeText
                        + " cr=" + crText + " acr=" + acrText)
        st = Pending(lr: st.lr, base: base, written: 0, fulfilled: false)
        pendingRequests[dataTask.taskIdentifier] = st

        // 关键：contentLength 必须是整个文件长度（Content-Range 的 /total），
        // contentType 必须是 UTI 而不是 MIME。填错 AVPlayer 会拒播或以为整集只有几十 KB。
        if let info = st.lr.contentInformationRequest, let http = response as? HTTPURLResponse {
            if let total = Self.contentRangeTotal(response) {
                info.contentLength = total
            } else if http.statusCode == 200, http.expectedContentLength > 0 {
                info.contentLength = http.expectedContentLength
            }
            info.contentType = Self.uti(forMime: http.mimeType)
            // 只有服务器真接受 Range（206 或声明了 Accept-Ranges）才敢说支持，
            // 否则 AVPlayer 会发起中段请求，而服务器只回 200 全量，等于白拉整集
            // 【v1.4.9】只有 206，或 Accept-Ranges 明确含 "bytes" 时才算支持。
            // 旧写法是「!= none」，nil（没这个头）也会被当成支持 —— 服务器根本没实现 Range，
            // AVPlayer 却会一直发中段请求，拿到 200 全量后卡住。
            let acceptRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
            info.isByteRangeAccessSupported = (http.statusCode == 206) || acceptRanges.contains("bytes")
        }
        // 服务器忽略 Range 回了 200，但 AVFoundation 要的是中段：立刻判死，
        // 别让用户对着"正在连接"等到 20 秒。
        if base == 0, let dr = st.lr.dataRequest, dr.requestedOffset > 0,
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           http.expectedContentLength > 0,
           Int64(http.expectedContentLength) <= dr.requestedOffset {
            st.lr.finishLoading(with: NSError(domain: "dshmedia", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "服务器忽略 Range 且长度不足（need \(dr.requestedOffset)）"]))
            pendingRequests.removeValue(forKey: dataTask.taskIdentifier)
            tasks.removeValue(forKey: ObjectIdentifier(st.lr))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    /// 收到数据块：按「当前需要的区间」切片立即 respond。
    /// 连续流的偏移 = base + written；只有落在 [requestedOffset, +requestedLength) 里的部分才写。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var st = pendingRequests[dataTask.taskIdentifier] else { return }
        guard let dr = st.lr.dataRequest else { st.written += Int64(data.count); pendingRequests[dataTask.taskIdentifier] = st; return }
        let chunkStart = st.base + st.written
        st.written += Int64(data.count)
        pendingRequests[dataTask.taskIdentifier] = st

        let wantLo = dr.requestedOffset
        // requestedLength 是 Int，offsets 是 Int64 —— 必须显式转，不然编译期就报
        // binary operator '+' cannot be applied to operands of type 'Int64' and 'Int'
        let wantHi = wantLo + Int64(dr.requestedLength)
        let chunkHi = chunkStart + Int64(data.count)
        // 200 响应 + 要求中段：数据从 0 开始，要丢掉前面的 (wantLo - 0) 字节
        let lo = max(wantLo, chunkStart)
        let hi = min(wantHi, chunkHi)
        if hi > lo {
            let off = Int(lo - chunkStart)
            let end = Int(hi - chunkStart)
            if end <= data.count, off < end {
                dr.respond(with: data.subdata(in: off..<end))
            }
        }
        // 已经写够了就不用再等剩下的字节（只有明确的区间请求才提前掐断）。
        // 掐之前先打 fulfilled：cancel 会让 didCompleteWithError 带一个 -999 回来，
        // 不标记的话会被当成真失败，界面直接跳「请求被系统中断」。
        if dr.requestsAllDataToEndOfResource == false, dr.requestedLength > 0,
           st.written >= (wantLo - st.base) + Int64(dr.requestedLength) {
            var done = pendingRequests[dataTask.taskIdentifier] ?? st
            done.fulfilled = true
            pendingRequests[dataTask.taskIdentifier] = done
            dataTask.cancel()
        }
    }

    /// 302 手动跟随：**不走 URLSession 自动跳转**，每跳重建 request 重新注入 headers 与 Range。
    /// 系统的 AVURLAsset 在跳转后会丢 header，xmcdn 第二跳因此 403 —— 这是我们自己跟随的全部理由。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let st = pendingRequests[task.taskIdentifier] else { completionHandler(nil); return }
        let hop = (redirectHops[ObjectIdentifier(task)] ?? 0) + 1
        redirectHops[ObjectIdentifier(task)] = hop
        guard hop <= 5 else {
            st.lr.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorHTTPTooManyRedirects,
                                              userInfo: [NSLocalizedDescriptionKey: "跳转超过 5 次"]))
            pendingRequests.removeValue(forKey: task.taskIdentifier)
            tasks.removeValue(forKey: ObjectIdentifier(st.lr))
            completionHandler(nil)
            return
        }
        var r2 = request
        r2.httpMethod = "GET"
        r2.timeoutInterval = 15
        r2.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (k, v) in headers { r2.setValue(v, forHTTPHeaderField: k) }
        if let range = originalRange[ObjectIdentifier(task)] {
            r2.setValue(range, forHTTPHeaderField: "Range")
        }
        CrashLog.write("PLAY", "redirect hop=\(hop) -> \(request.url?.host ?? "?")")
        completionHandler(r2)
    }

    /// 完成：成功就 finishLoading，失败就 finishLoading(with:)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            redirectHops.removeValue(forKey: ObjectIdentifier(task))
            originalRange.removeValue(forKey: ObjectIdentifier(task))
        }
        guard let st = pendingRequests.removeValue(forKey: task.taskIdentifier) else { return }
        // didCancel 已经把它从表里摘掉，这里就不再回调（避免 finishLoading 两次）
        tasks.removeValue(forKey: ObjectIdentifier(st.lr))
        if let e = error as NSError?, e.code == NSURLErrorCancelled {
            if st.lr.isFinished { return }
            if st.fulfilled {
                // 我们自己写够了才掐的，-999 只是取消通知，按成功收尾
                st.lr.finishLoading()
                return
            }
        }
        if let error = error, !st.fulfilled {
            st.lr.finishLoading(with: error)
            return
        }
        // 走到这里说明数据已按片回填完，收尾
        if !st.lr.isFinished { st.lr.finishLoading() }
    }

    private var redirectHops: [ObjectIdentifier: Int] = [:]
    private var originalRange: [ObjectIdentifier: String] = [:]
    /// Content-Range 的 /total 段（整集字节数）。取不到返回 nil。
    private static func contentRangeTotal(_ resp: URLResponse?) -> Int64? {
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = cr.lastIndex(of: "/") else { return nil }
        let s = cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let v = Int64(s), v > 0 else { return nil }
        return v
    }

    /// MIME → UTI。给错的 UTI 会让 AVPlayer 拒播，识别不了就交 public.audio 让它自己嗅探。
    private static func uti(forMime mime: String?) -> String {
        let m = (mime ?? "").lowercased()
        if m.contains("mpeg") { return "public.mp3" }
        if m.contains("mp4") || m.contains("m4a") || m.contains("aac") { return "public.mpeg-4-audio" }
        if m.contains("wav") { return "com.microsoft.waveform-audio" }
        return "public.audio"
    }

    /// 206 响应的 Content-Range: bytes 0-1048575/5242880 → 0；200 响应 → 0
    private static func contentRangeStart(_ resp: URLResponse?) -> Int64 {
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206,
              let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let sp = cr.firstIndex(of: " "), let dash = cr.firstIndex(of: "-") else { return 0 }
        let s = cr[cr.index(after: sp)..<dash].trimmingCharacters(in: .whitespaces)
        return Int64(s) ?? 0
    }
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
    /// 起播进度的口语化提示（「正在取地址…」「正在连接…」「正在解码…」），
    /// 与 state 分开：state 只有 4 态，用户需要知道「卡在哪一步」。
    @Published private(set) var stageHint: StartStage = .idle

    /// 起播四阶段。失败文案必须带上它，否则用户只会看到「播放失败」四个字。
    enum StartStage: String {
        case idle, resolving, connecting, decoding, playing
        var label: String {
            switch self {
            case .idle, .resolving: return "正在取地址…"
            case .connecting: return "正在连接源站…"
            case .decoding: return "正在解码…"
            case .playing: return "播放中"
            }
        }
    }

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
        stageHint = .idle
        errorText = "取地址失败：" + msg      // 阶段前缀：用户能分清是引擎侧还是播放器侧
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
        // 阶段前缀：加载阶段 / 解码阶段分开，用户截图能直接定位
        let stage: String = state == .playing ? "解码" : "加载"
        errorText = "【" + stage + "】" + msg
        stageHint = .idle
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
    /// 「已 ready 但时间不走」哨兵（与起播看门狗分开，ready 之后接手）
    private var progressWatchdog: Task<Void, Never>?
    /// 已经降级重试过的 trackId（同一个 item 只降级一次，防循环）
    private var fallbackTriedTrack: Int64 = -1
    /// 当前 item 的请求头（降级重试要用）
    private var currentHeaders: [String: String] = [:]
    /// 当前这次起播走的哪条路（local / remote / remote-loader），失败时决定回退策略
    private var viaOfCurrent: String = ""
    /// 当前 item 的源地址（重建立 AVURLAsset 用）
    private var currentAssetURL: URL?
    /// 未包装的原始 http(s) URL（loader 场景下 currentAssetURL 可能被 scheme 替换前的副本）
    private var currentOriginalURL: URL?
    /// 待执行的续播/跳片头位置（毫秒）。ready 之后由 applyPendingStartSeek() 校验后执行。
    private var pendingStartSeekMs: Int64?
    /// 本次起播的墙钟时刻。① 判断 stalled 是不是「起播阶段」 ② 计时播完的自动续章
    private var startedAt: Date = .distantPast
    /// AVAsset 只弱引用 resourceLoader 的 delegate，必须由我们强持有一份，
    /// 否则 item 还没 ready 就被释放 → 永远不 ready（这是最隐蔽的一条）。
    private var loaderRetainer: ResourceLoaderDelegate?

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
    var currentAuthor: String { currentBook?.author ?? "" }
    var currentBookUrl: String { currentBook?.bookUrl ?? "" }
    var currentAlbumId: Int64 { currentBook?.albumId ?? 0 }
    var currentIsFavorite: Bool {
        guard let book = currentBook else { return false }
        return LocalStore.isFavorite(sourceId: currentSourceId,
                                     albumId: book.albumId, bookUrl: book.bookUrl)
    }
    var currentVolumeGainDb: Double { effectivePlayback.volumeGainDb }
    var sleepRemainingMinutes: Int {
        guard let sleepDeadline else { return 30 }
        return max(0, Int(ceil(sleepDeadline.timeIntervalSinceNow / 60)))
    }

    /// 章节列表的 UI 快照，避免视图层接触共享模型。
    struct ChapterSnapshot: Identifiable {
        let id: Int64
        let title: String
        let number: Int
        let trackId: Int64
    }

    var chapterSnapshots: [ChapterSnapshot] {
        currentEpisodes.map {
            ChapterSnapshot(id: $0.trackId, title: $0.title,
                            number: Int($0.index), trackId: $0.trackId)
        }
    }

    var currentTrackId: Int64? { current?.trackId }
    var canGoPreviousChapter: Bool { chapter(offset: -1) != nil }
    var canGoNextChapter: Bool { chapter(offset: 1) != nil }
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
        // 【v1.4.6】倍速不是 @Published，改完不通知，底部 dock 的旋转角速度就更新不了
        // （spinSignature 依赖 currentSpeed，没有 objectWillChange 就不会重算）。
        objectWillChange.send()
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

        // 【2026-11-25 P0】引擎已经明确告诉我们这集有没有直链了。
        // 以前这里不看 playable，一律去取地址：喜马 VIP 轨 playUrl 空 → 引擎拿网页顶上 →
        // 出口闸拦住 → 用户看到「只给了网页地址」，完全不知道是要钱。
        // 现在直接拿 hint 说话，并且不发那次注定失败的请求。
        guard ep.playable else {
            requestingEpisode = false
            failAddress(ep.hint.isEmpty ? "本集暂时无法播放" : ep.hint)
            return
        }

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
                self.failAddress(SharedBridge.lastAudioError ?? Player.fallbackAddressReason(src))
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

        guard ep.playable else {
            requestingEpisode = false
            failAddress(ep.hint.isEmpty ? "本集暂时无法播放" : ep.hint)
            return
        }

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
            // 登录版这条链也要补兜底 UA：引擎部分分支返回空 headers，
            // 裸请求打 xmcdn 直接 403（实测 deny by rule engine），表现就是起播超时。
            // 按源那条 playEpisode 早就补了，这条漏了 —— 两条入口行为必须一致。
            let fixed = SharedBridge.audioWithDefaultUA(audio)
            self.startItem(url: u, headers: fixed.headers, ep: ep)
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
        stageHint = .resolving
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
            // 不是所有 CDN 都支持 HEAD（实测 B 站 mcdn HEAD 404、GET Range 206 正常），
            // 直接用带 Range 的 GET 探 1 字节：既有状态码也有 Content-Type，还不下载整集。
            req.httpMethod = "GET"
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
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
            // 上面那条 Range GET 已经覆盖了「HEAD 不支持」的情况，这里只记失败
            CrashLog.write("PLAY", "probe track=" + String(trackId) + " failed (no response)")
        }
    }


    /// 网页地址判定：复用 SharedBridge.looksLikeWebPage（/sound/ /album/ 门户域），
    /// 再补一条它没覆盖的 —— 路径末段没有扩展名（如 /sound/1011694179 以外的 /v/123）。
    private func isWebPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if SharedBridge.looksLikeWebPage(url.absoluteString) { return true }
        let path = url.path.lowercased()
        if path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix(".php") { return true }
        // 末段没有扩展名 → 也不当音频。但**必须排除**中转型直链：
        // 模板站的 /program/get-source/123 这类是没有扩展名的合法音频口，
        // 一刀切会把它们全拦掉，又是一批源播不了。
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last.contains(".") { return false }
        let relayMarks = ["/program/get-source/", "/get-source/", "/play/", "/stream/", "/redirect"]
        let low = url.absoluteString.lowercased()
        if relayMarks.contains(where: { low.contains($0) }) { return false }
        return true
    }

    private func startItem(url: URL, headers: [String: String], ep: SharedBridge.EpisodeRow) {
        // 【P0 2026-11-24】闸：网页地址不许交给 AVPlayer（否则只会得到 -12847）。
        // 真机日志：start remote host=www.ximalaya.com → resp code=200 mime=text/html → OSStatus -12847。
        // 引擎侧已加出口校验（AudioUrlHeaders.requirePlayable），这里是第二道闸：
        // 老版本引擎、payload 兜底、任何绕过引擎的路径都不该把 text/html 塞进播放器。
        if isWebPageURL(url) {
            CrashLog.write("PLAY", "REJECT webpage-as-audio track=\(ep.trackId) src=\(currentSourceId) url=\(url.absoluteString.prefix(120))")
            requestingEpisode = false
            failAddress("源站只给了网页地址，没给音频直链")
            return
        }
        CrashLog.write("PLAY", "start remote track=\(ep.trackId) src=\(currentSourceId) scheme=\(url.scheme ?? "") host=\(url.host ?? "")")
        // 起播后按上次配置恢复睡眠定时（sleepAutoEnable 打开时生效）
        if sleepDeadline == nil, sleepChaptersLeft <= 0 { restoreSleepTimerIfNeeded() }
        requestingEpisode = false
        BackgroundSession.activateForPlayback()

        // 缓存优先：已缓存的集直接播本地文件（离线可用）。
        // 本地文件同样要挂 status 观察 —— 以前走 startItemWithLocalFile 时状态停在 .playing，
        // 文件被系统清掉/截断时界面永远卡「播放中」，也是「点第一集没反应」的一条来源。
        // 【P0 v1.4.8】缓存命中必须做内容校验。
        // 真机日志：命中缓存 → start local → status 永远 0 →「轮盘一直转但没声音」。
        // 缓存里存的是错误页 HTML（模板站对无 Referer 请求回 200 + text/html），
        // 旧代码只判 size>16KB，9780079 字节的 HTML 轻松过关；cachedFile 每次命中还刷 mtime，
        // LRU 永远清不掉，于是每次都播同一个坏文件。
        if let cached = AudioCache.playableCachedFile(bookUrl: currentBook?.bookUrl ?? "",
                                                 trackId: ep.trackId) {
            // 必须先记下这一集的远程 URL 与 headers ——
            // 下面的 beginPlayback 会用它收到的 headers 覆盖 currentHeaders，
            // 而 currentOriginalURL 只有 remote 分支才赋值（在 return 之后）。
            // 不在这里补，本地播放失败要回退远程时用的是上一集的陈旧 URL ——
            // 轻则播错书，重则取不到地址。
            currentOriginalURL = url
            let litem = AVPlayerItem(url: cached)
            beginPlayback(litem, ep: ep, via: "local", headers: headers, sourceURL: cached)
            // 【v1.4.9-R4 P0】以前这里写的是 headers: [] 再在下一行补写 currentHeaders。
            // 问题不在补写，在时间窗：beginPlayback 里 detachItem() 会让被摘掉的 item
            // 立刻补一次 .failed(-999)，handleStatus 判到 viaOfCurrent == local 就删缓存并
            // startItem(url: currentOriginalURL, headers: currentHeaders) —— 那一刻
            // currentHeaders 还是刚被清空的空字典，拿空头去打 xmcdn/kuwo 必 403，
            // 用户看到的就是「缓存里的书突然播不了」。现在直接把真 headers 传进去。
            currentOriginalURL = url
            // 幂等保险：防止将来有人把 beginPlayback 的写法改回去。
            currentHeaders = headers
            return
        }

        let (item, loader) = newItemWithLoader(url: url, headers: headers)
        if loader != nil {
            // 带 header 的请求必须记下「原始 URL」，降级重试时还要用
            currentOriginalURL = url
        }
        beginPlayback(item, ep: ep, via: loader != nil ? "remote-loader" : "remote",
                      headers: headers, sourceURL: url, loader: loader)
    }

    /// 引擎没给具体原因时的兜底文案。按源分开，免得用户看到一句万能废话：
    /// 网易云走的是 meting 代理，代理挂了/歌曲下架都表现成「播不了」，
    /// 说成「源站返回了网页」会把排查方向带偏。
    static func fallbackAddressReason(_ sourceId: String) -> String {
        switch sourceId {
        case "netease": return "网易云代理没返回音频（代理可能挂了，或这首歌已下架）"
        case "kuwo": return "酷我没有返回可播地址（可能要会员，或该曲已下架）"
        case "bilibili": return "B 站没有返回可播音频（可能是番剧/付费内容，或该分片已失效）"
        case "qingting": return "蜻蜓没有返回可播地址（该节目可能需要登录或已下架）"
        case "ximalaya", "ximalaya-open": return "喜马拉雅没有返回可播地址（可能需要登录或已下架）"
        default: return "这个源取不到播放地址"
        }
    }
    /// 建 item。三条路，按「能带 header 且不会挂住 asset」的优先级排：
    ///
    /// A. 有 header + http(s) → 自定义 scheme + ResourceLoaderDelegate（主力）。
    ///    只有这条能保证 302 跳转后仍带 header，且不依赖非公开 API。
    /// B. `AVURLAssetHTTPHeaderFieldsKey` 仍然挂上（老系统兜底）。
    ///    注意：这个 key 是非公开 API，iOS 16+ 起不保证生效；更糟的是某些系统版本上
    ///    带一个它不认识的 option 会让 asset 加载挂住 —— 所以 A 生效时 B 只是陪跑，
    ///    delegate 拿到请求后照样自己发，系统那个 attempt 失败不影响播放。
    /// C. 无 header / file:// → 普通 AVURLAsset，绝不下发 options。
    ///
    /// 返回的 delegate 必须被调用方强引用住（AVAsset 只弱引用它），否则会被释放，
    /// 表现就是「有声音但没有回调」或「一直不 ready」。
    private func newItemWithLoader(url: URL, headers: [String: String]) -> (AVPlayerItem, ResourceLoaderDelegate?) {
        let scheme = (url.scheme ?? "").lowercased()
        var assetURL = url
        var loader: ResourceLoaderDelegate?
        var opts: [String: Any] = [:]
        if !headers.isEmpty, scheme == "http" || scheme == "https" {
            if let wrapped = ResourceLoaderDelegate.wrap(url) {
                assetURL = wrapped
                let d = ResourceLoaderDelegate(headers: headers)
                loader = d
                opts["AVURLAssetHTTPHeaderFieldsKey"] = headers     // B：老系统兜底
            }
        }
        let asset = AVURLAsset(url: assetURL, options: opts.isEmpty ? nil : opts)
        if let d = loader {
            // 必须给 .main：URLSession 的回调也在 .main，两边同域才能安全回填
            // （AVAssetResourceLoadingRequest 不是线程安全的，跨线程 respond 会随机崩）
            asset.resourceLoader.setDelegate(d, queue: .main)
        }
        let item = AVPlayerItem(asset: asset)
        if LocalStore.loadPlayPrefs().skipSilence, #available(iOS 16.4, *) {
            item.audioTimePitchAlgorithm = .timeDomain
        }
        CrashLog.write("PLAY", "asset scheme=\(assetURL.scheme ?? "-") loader=\(loader != nil) hdr=\(headers.count)")
        return (item, loader)
    }

    /// 唯一的挂载入口（remote / local / 降级重试都走这里）。
    /// 顺序不可换：detach 旧观察 → pause → removeAllItems → insert → attach。
    /// 先 pause 再清队列：AVQueuePlayer 在 playing 状态下换 items 会走「等待最小化卡顿」，
    /// 拿 0 速率去看似 ready 的 item 上等，真机上是点进去一直转的直接来源。
    private func beginPlayback(_ item: AVPlayerItem, ep: SharedBridge.EpisodeRow,
                               via: String, headers: [String: String], sourceURL: URL,
                               loader: ResourceLoaderDelegate? = nil) {
        // 主路径是 remote-loader（带 header）；只判 "remote" 等于对 99% 的播放不做探测
        if via.hasPrefix("remote"), AudioCache.loadSettings().autoCacheNext {
            // 边播边缓存：起播后异步取标头（见 cacheHeaders 注释里为何不再整段下载）
            cacheInBackground(url: sourceURL, headers: headers)
        }
        currentHeaders = headers
        currentAssetURL = sourceURL
        viaOfCurrent = via
        // 原样核对引擎给的 header：重复 key（大小写不同）、空值、非法字段都会让
        // AVFoundation 整份丢弃。这里只记 key + 值长度，不落敏感值。
        let hdrDump = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { $0.key + ":" + String($0.value.count) }
            .joined(separator: ",")
        CrashLog.write("PLAY", "headers " + (hdrDump.isEmpty ? "-" : hdrDump))
        // 老 loader 释放前先关掉它的 session，避免残留连接把源站并发占满
        loaderRetainer?.tearDown()
        loaderRetainer = loader
        // 注意：pendingStartSeekMs 在这之前刚被赋值（本集的目标位置），
        // detachItem 不能清它 —— 清空只发生在 stop()/retry() 这类「不要续播」的路径。
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
        stageHint = .connecting
        durationText = fmt(ep.durationMs)
        // 音量增益：远程路径同样要应用（之前只接了本地缓存分支，等于网播时设置无效）
        applyVolumeGain()
        let sp = effectivePlayback.speed
        queue.rate = Float(sp.isFinite && sp > 0 ? min(3.0, max(0.5, sp)) : 1.0)
        apply(.playing)

        // 续播：**不当场 seek**，只算出目标时间挂起来，等 status == .readyToPlay 再执行。
        // 原因：item 还没 ready 时 duration 是 NaN/0，此时 seek 到 1 分钟以外的位置，
        // 对 1 分钟的短音频 + 片头 30 秒的组合会直接越界（seek 到末尾 → 立即播完 → 自动跳下一集，
        // 用户看到的是「点进去就切走了」）。校验必须拿 ready 之后的真实 duration。
        pendingStartSeekMs = nil
        if let b = currentBook,
           let saved = LocalStore.progress(for: BookKey(sourceId: currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)),
           saved.trackId == (current?.trackId ?? -1), saved.positionMs > 3000,
           saved.durationMs > 0, Double(saved.positionMs) / Double(saved.durationMs) < 0.95 {
            // 恢复播放时按偏好后退几秒，防听漏（安卓设置页第 7 项）
            let rewind = Int64(LocalStore.loadPlayPrefs().resumeRewindSeconds) * 1000
            pendingStartSeekMs = max(0, saved.positionMs - rewind)
            position = min(1.0, Double(saved.positionMs) / Double(max(saved.durationMs, 1)))
            elapsedText = fmt(max(0, saved.positionMs - rewind))
        } else if effectivePlayback.skipIntroSec > 0 {
            // 跳过片头（每集开头常有一段片头/广告），同样等 ready
            pendingStartSeekMs = Int64(effectivePlayback.skipIntroSec) * 1000
            elapsedText = fmt(pendingStartSeekMs ?? 0)
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
        advanceAfterEnding(from: ep, skipped: 0)
    }

    /// 自动连播的下一条。遇到不可播的集（VIP/付费/已失效）就跳过继续找，
    /// 最多连跳 3 集 —— 整本都不可播时不能无限递归，停下来把原因显示给用户。
    /// 必须带 episodes: currentEpisodes：不传的话 playEpisode 会把队列清空，
    /// 跳一条之后「下一集」就永远拿不到了。
    private func advanceAfterEnding(from ep: SharedBridge.EpisodeRow, skipped: Int) {
        guard let next = nextEpisode(after: ep, forward: !effectivePlayback.reverseOrder) else {
            apply(.paused)
            updateNowPlayingInfo()
            return
        }
        guard next.playable else {
            CrashLog.write("PLAY", "auto skip unplayable track=\(next.trackId) skipped=\(skipped + 1)")
            guard skipped < 2 else {
                // 连续三集都不可播：停在这里，把最后一集的原因说清楚
                pause()
                failAddress(next.hint.isEmpty ? "连续多集无法播放，已停止自动连播" : next.hint)
                updateNowPlayingInfo()
                return
            }
            advanceAfterEnding(from: next, skipped: skipped + 1)
            return
        }
        playEpisode(next, book: currentBook, sourceId: currentSourceId, episodes: currentEpisodes)
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

    private func chapter(offset: Int) -> SharedBridge.EpisodeRow? {
        guard let current,
              let idx = currentEpisodes.firstIndex(where: { $0.trackId == current.trackId }) else { return nil }
        let target = idx + offset
        guard target >= 0, target < currentEpisodes.count else { return nil }
        return currentEpisodes[target]
    }

    func goToChapter(offset: Int) {
        guard let episode = chapter(offset: offset) else { return }
        playEpisode(episode, book: currentBook, sourceId: currentSourceId,
                    episodes: currentEpisodes)
    }

    func playChapter(trackId: Int64) {
        guard let episode = currentEpisodes.first(where: { $0.trackId == trackId }) else { return }
        playEpisode(episode, book: currentBook, sourceId: currentSourceId,
                    episodes: currentEpisodes)
    }

    @discardableResult
    func toggleCurrentFavorite() -> Bool {
        guard let book = currentBook else { return false }
        return LocalStore.toggleFavorite(
            bookUrl: book.bookUrl, title: book.title, author: book.author,
            coverUrl: book.coverUrl, albumId: book.albumId,
            sourceId: currentSourceId
        )
    }

    func setVolumeGain(_ db: Double) {
        let value = db.isFinite ? min(12, max(-12, db)) : 0
        persistPlayback { $0.volumeGainDb = value }
        applyVolumeGain()
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
        // 登记「是我们主动摘的」—— 只有这些 item 的失败才该被忽略。
        // AVQueuePlayer 自己踢掉的 failed item 不进这个集合，它们的错误必须报出来。
        if let cur = observedItem { orphanedItems.insert(ObjectIdentifier(cur)) }
        if orphanedItems.count > 8 { orphanedItems.removeAll() }   // 防止无限增长
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

    /// 执行 beginPlayback 挂起的续播/跳片头。
    ///
    /// 为什么必须等 ready：item 未 ready 时 duration 是 NaN/0，seek 到越界位置会被 AVPlayer
    /// 钳到末尾 -> 立刻触发 end -> 自动跳下一集，用户看到的就是「点进去自己切走了」。
    /// 这里用 ready 之后的真实 duration 做三道校验：
    ///   1 目标 >= duration - 1000ms（差不到 1 秒就播完）-> 放弃续播，从头放；
    ///   2 目标 <= 1000ms -> 等于从头，直接跳过，省一次 seek；
    ///   3 其余情况 seek，并把真实 duration 回填给 UI，进度条立刻正确。
    private func applyPendingStartSeek(_ item: AVPlayerItem) {
        guard let targetMs = pendingStartSeekMs else { return }
        pendingStartSeekMs = nil
        let durCM = item.duration
        // readyToPlay != duration 已知。m4s / fragmented MP4 / octet-stream 在这一刻
        // 常常还是 indefinite（.seconds 返回 nan 或 inf）。这时候丢掉续播位置是错的降级：
        // 用户会以为进度丢了。所以挂回去，等 duration KVO 到数再来一次。
        guard durCM.isNumeric, !durCM.isIndefinite else {
            CrashLog.write("PLAY", "pending seek deferred: duration indefinite")
            pendingStartSeekMs = targetMs
            return
        }
        let durSec = durCM.seconds
        guard durSec.isFinite, durSec > 0 else {
            CrashLog.write("PLAY", "pending seek dropped: duration invalid")
            return
        }
        let durMs = Int64(durSec * 1000)
        if targetMs >= durMs - 1000 {
            CrashLog.write("PLAY", "pending seek dropped: target=\(targetMs) dur=\(durMs)")
            position = 0
            elapsedText = fmt(0)
            return
        }
        if targetMs <= 1000 { return }
        queue.seek(to: CMTime(value: CMTimeValue(targetMs), timescale: 1000),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        position = min(1.0, Double(targetMs) / Double(durMs))
        elapsedText = fmt(targetMs)
        durationText = fmt(durMs)
        CrashLog.write("PLAY", "pending seek applied ms=\(targetMs) dur=\(durMs)")
    }

    /// status 三态。.unknown 是 KVO 的 .initial 首次回调（每个新 item 必来一次），
    /// 此时 asset 还在加载，什么都不该做 —— 更不能当失败。
    /// .failed 要分两种：用户自己换台导致的 -999 与真失败，见 isSelfInflictedCancel。
    private func handleStatus(_ item: AVPlayerItem) {
        guard item === observedItem else { return }
        switch item.status {
        case .readyToPlay:
            cancelStartWatchdog(reachedReady: true)
            applyPendingStartSeek(item)
            armProgressWatchdog(gen: requestGeneration)     // ready 之后由它盯「播不动」
            if state == .loading || state == .playing { stageHint = .decoding }
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
            // 本地缓存坏了（status=.failed）→ 删掉这个文件并立刻改走网络，
            // 否则用户点「重试」每次都命中同一个坏文件，永远播不了。
            if viaOfCurrent == "local", let cached = currentAssetURL {
                try? FileManager.default.removeItem(at: cached)
                CrashLog.write("PLAY", "bad local cache deleted track=" + String(current?.trackId ?? 0))
                if let ep = current, let src = currentOriginalURL {
                    startItem(url: src, headers: currentHeaders, ep: ep)
                    return
                }
                if let ep = current {
                    playEpisode(ep, book: currentBook, sourceId: currentSourceId)
                    return
                }
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
        stageHint = .decoding          // 播着播着卡住：界面显示「正在解码…」，不是「正在连接」
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
    /// 我们**主动**摘掉的 item 集合（detachItem 时登记）。
    /// 判「-999 是不是我们自己造成的」只能看这个集合，不能看「队列里还有没有它」——
    /// AVQueuePlayer 在 item 解码失败时会**自己**把它踢出队列，那种情况 currentItem 也会变 nil，
    /// 用它当判据就会把真实错误当成「换台残响」吞掉（真机日志：ignore stale item failure + 永远转圈）。
    private var orphanedItems = Set<ObjectIdentifier>()

    /// 判断一个报错的 item 是不是「我们已经主动换掉/清掉」的那一个。
    private func isSelfInflictedCancel(_ item: AVPlayerItem) -> Bool {
        orphanedItems.contains(ObjectIdentifier(item))
    }

    /// 起播看门狗。**单一 deadline 驱动**，不是嵌套 sleep + return ——
    /// 原实现在 T+20s 那段 `guard it.status != .readyToPlay else { return }`，
    /// ready 之后整个任务就结束了，「ready 了但时间不走（解码卡死）」没有任何人管。
    ///
    /// 阶段：
    ///   T+6s   未 ready → stageHint = .connecting，不报错（弱网首包 6~15 秒是常态）
    ///   T+20s  未 ready → fallbackWithoutHeadersIfPossible 降级一次；**不结束任务**
    ///   T+20s  已 ready → 进入「推进检查」：每 2 秒采一次 currentTime，
    ///                     连续 30 秒没前进 → failPlayback("【解码】音频已就绪但播不动")
    ///          未 ready → 降级后仍等 14 秒，T+34s 仍未 ready 才报「加载」失败
    private func armStartWatchdog(ep: SharedBridge.EpisodeRow) {
        cancelStartWatchdog(reachedReady: nil)
        let gen = requestGeneration
        let track = ep.trackId
        let start = Date()
        startWatchdog = Task { @MainActor in
            var didWarn6 = false
            var didFallback = false
            var fallbackAt: Date?
            var lastPos: Double = -1
            var lastMoveAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                // 换台/换集：整个任务作废
                guard gen == self.requestGeneration, self.current?.trackId == track else { return }
                guard let it = self.observedItem else { return }
                let elapsed = Date().timeIntervalSince(start)
                let ready = (it.status == .readyToPlay)

                if !ready {
                    if !didWarn6, elapsed >= 6 {
                        didWarn6 = true
                        self.stageHint = .connecting
                        self.errorText = nil
                        CrashLog.write("PLAY", "watchdog T+6s not ready track=\(track)")
                    }
                    if !didFallback, elapsed >= 20 {
                        didFallback = true
                        fallbackAt = Date()
                        if self.fallbackWithoutHeadersIfPossible(reason: "start timeout 20s") {
                            // 降级会重建 item 并重启看门狗，本任务到这就交棒
                            return
                        }
                    }
                    if let fa = fallbackAt, Date().timeIntervalSince(fa) >= 14 {
                        self.failPlayback("音频加载失败（等待 20 秒仍未就绪，降级后仍无响应：源站拒绝或地址已失效）")
                        return
                    }
                    if !didFallback, elapsed >= 34 {
                        self.failPlayback("音频加载失败（等待 34 秒仍未就绪：源站无响应）")
                        return
                    }
                    continue
                }

                // ---- 已 ready：检查时间是否在走 ----
                self.cancelStartWatchdog(reachedReady: true)   // 走完这一步就不再需要「起播」判定
                return
            }
        }
    }

    /// 「已 ready 但播不动」的独立哨兵。与起播看门狗分开：
    /// 起播只关心 status 有没有到 readyToPlay；到了之后卡住是解码/防盗链层面的问题，
    /// 由这个 30 秒无推进判定，文案单列「【解码】音频已就绪但播不动」。
    private func armProgressWatchdog(gen: Int) {
        progressWatchdog?.cancel()
        let track = current?.trackId ?? 0
        progressWatchdog = Task { @MainActor in
            var lastPos = -1.0
            var lastMove = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard gen == self.requestGeneration, self.current?.trackId == track else { return }
                guard self.state == .playing || self.state == .loading else { return }
                let pos = self.queue.currentTime().seconds
                // 暂停/拖动都会让 pos 变动，只有「同一位置连续 30 秒」才算卡死
                // 播放中 seek 会让 pos 往回跳，这里只认「变了」，不管方向
                if pos != lastPos {
                    lastPos = pos
                    lastMove = Date()
                    continue
                }
                if Date().timeIntervalSince(lastMove) >= 30 {
                    self.failPlayback("音频已就绪但播不动（30 秒没有前进：可能是解码失败或源站只给了开头一段）")
                    return
                }
            }
        }
    }

    private func cancelProgressWatchdog() {
        progressWatchdog?.cancel()
        progressWatchdog = nil
    }

    /// 取消看门狗。reachedReady 只用于日志：判定本身靠「同一个代际 + 同一个 trackId + item 仍未 ready」。
    private func cancelStartWatchdog(reachedReady: Bool?) {
        if let why = reachedReady {
            CrashLog.write("PLAY", "watchdog cancel ready=\(why)")
        }
        startWatchdog?.cancel()
        startWatchdog = nil
        if reachedReady != nil { cancelProgressWatchdog() }   // 只在「确定结束」时停推进哨兵
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
        let (it, loader) = newItemWithLoader(url: url, headers: [:])
        beginPlayback(it, ep: ep, via: "remote-plain", headers: [:], sourceURL: url, loader: loader)
        return true
    }

    /// AVFoundation 的 NSURLError 原文 → 人话。原文太长，用户看不懂也不该看。
    /// AVFoundationErrorDomain 的 -11800 是「万能壳」，真正原因埋在 userInfo[NSLocalizedFailureReasonErrorKey]
    /// 的 underlying error 里（通常是 NSURLErrorDomain -1008/-1009/-1200 或 -11828 解码失败）。
    /// 以前只打 -11800 等于什么都没说，这次把底层 reason 与 underlying code 一并挖出来。
    private static func describe(_ error: Error?) -> String {
        guard let error = error else { return "音频无法播放（源站没有响应）" }
        let ns = error as NSError
        var code = ns.code
        var domain = ns.domain
        var reason = (ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String) ?? ns.localizedDescription
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            code = under.code
            domain = under.domain
            let r2 = (under.userInfo[NSLocalizedFailureReasonErrorKey] as? String) ?? under.localizedDescription
            if !r2.isEmpty { reason = r2 }
        }
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorTimedOut: return "连接超时（源站没在 15 秒内回第一个包）"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "连不上源站服务器"
            case NSURLErrorNetworkConnectionLost: return "网络中断，播放已停止"
            case NSURLErrorNotConnectedToInternet: return "当前没有网络"
            case NSURLErrorSecureConnectionFailed: return "HTTPS 证书不被信任"
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "音频地址不合法（源站返回的地址拼坏了）"
            case 403: return "源站拒绝了这个请求（403，多半是防盗链要 Referer/UA）"
            case 404: return "音频文件不存在（404，源站已下架或地址过期）"
            case NSURLErrorCancelled: return "请求被系统中断（源站主动断开）"
            default: break
            }
        }
        // 解码层：-11828 是「格式不被支持」，常见于源站把错误页当音频返回
        if code == -11828 { return "音频格式不支持（源站可能返回了网页而不是音频）" }
        if code == -11800 { return "音频解码失败：" + reason }
        return reason.isEmpty ? "音频无法播放（错误码 " + String(code) + "）" : ("音频无法播放：" + reason + "（" + String(code) + "）")
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
        // 暂停 = 用户不再等着听，30 秒无推进不该算卡死。
        // 旧版不取消：暂停着听到锁屏超时，回来就是一条「播不动」错误页。
        progressWatchdog?.cancel()
        progressWatchdog = nil
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
        // 暂停时 progressWatchdog 已经 return 结束，恢复播放不会重新经过 readyToPlay，
        // 不补这一步的话，暂停过再播的集之后真卡死 30 秒也没人报，界面永远停在「播放中」。
        armProgressWatchdog(gen: requestGeneration)
    }

    func stop() {
        saveProgress(force: true)
        // 停止要连「播不动」哨兵一起收掉，否则它会继续跑 30 秒才自己退出
        progressWatchdog?.cancel()
        progressWatchdog = nil
        // 停止后不再续播：挂起的起播位置必须作废，否则下次 playEpisode 会沿用上一次的目标
        pendingStartSeekMs = nil
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
        // 打断恢复同样要重新武装「播不动」哨兵：暂停时已经 cancel 掉了，
        // 这条路径不经过 resume()，不补就整段监听缺失（第四轮播放器复检指出）。
        armProgressWatchdog(gen: requestGeneration)
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
