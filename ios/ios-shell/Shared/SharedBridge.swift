import Foundation
import shared

/// 壳 ↔ 共享核心唯一对接层（契约 v1.1：framework 产物名 shared）。
/// 白名单：本文件是壳内唯一允许 import shared 的文件，只消费结果模型
/// Book / BookDetail / Episode / SearchResult / ExtractedAudio / SourceErrors；
/// 引擎网络栈与解析器类型一律不得出现在壳内任何 Swift 文件
/// （C1 机械检查线：check-whitelist.sh 本机跑，CI 同口径）。
///
/// v1.1 对齐（docs/契约v1.1字段增量对照表.md · commit f3e75b4）：
/// - Book 增量：albumId/trackCount/playCount/isFinished(Boolean?→NSNumber?)
/// - Episode 增量：trackId/index(Int→Int32)/durationMs(毫秒)/coverUrl
/// - SearchResult 增量：source/page/hint(String?→Optional)
/// - ExtractedAudio 增量：expiresInSeconds(时效秒，UI 可显示)
/// - SourceErrors.Network.cause → reason（唯一破坏性改名，已按 reason 消费）
/// 桥接纪律（对照表 §二）：sealed 错误族 = 基类+子类，匹配用 is/as? 链（不用 enum
/// case 语法）；List<T> 桥接 NSArray，消费前防御转 [T]；data class init 全参无默认值；
/// Long→Int64 / Int→Int32；String?/Boolean? 一律判空，禁 ! 强解。
/// 命名对拍：framework 首产物头文件为准（nm -gU / 类名回填），Mac 窗口第 2 步执行。
enum SharedBridge {

    // MARK: - 书架卡片（v1.1 全字段消费；bookUrl 形态 = /album/{albumId}）
    struct BookCard: Codable {
        let bookUrl: String
        let title: String
        let author: String
        let coverUrl: String
        let albumId: Int64          // 数值专辑 ID，直拼 URL 免正则
        let trackCount: Int64       // 总集数（书架角标）
        let playCount: Int64        // 播放量（「2887万播放」）
        let isFinished: Bool?       // nil = 上游未给，UI 不渲染
        var intro: String = ""      // 专辑简介（详情页展示）

        /// 手写解码：intro 是后加的字段，旧缓存里没有，必须 decodeIfPresent
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookUrl = try c.decode(String.self, forKey: .bookUrl)
            title = try c.decode(String.self, forKey: .title)
            author = try c.decode(String.self, forKey: .author)
            coverUrl = try c.decode(String.self, forKey: .coverUrl)
            albumId = try c.decode(Int64.self, forKey: .albumId)
            trackCount = try c.decode(Int64.self, forKey: .trackCount)
            playCount = try c.decode(Int64.self, forKey: .playCount)
            isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished)
            intro = try c.decodeIfPresent(String.self, forKey: .intro) ?? ""
        }

        init(bookUrl: String, title: String, author: String, coverUrl: String,
             albumId: Int64, trackCount: Int64, playCount: Int64, isFinished: Bool?, intro: String = "") {
            self.bookUrl = bookUrl; self.title = title; self.author = author
            self.coverUrl = coverUrl; self.albumId = albumId
            self.trackCount = trackCount; self.playCount = playCount
            self.isFinished = isFinished; self.intro = intro
        }
    }

    static func card(from b: Book) -> BookCard {
        BookCard(
            bookUrl: b.bookUrl,
            title: b.title,
            author: b.author,
            coverUrl: b.coverUrl,
            albumId: b.albumId,
            trackCount: b.trackCount,
            playCount: b.playCount,
            isFinished: (b.isFinished as NSNumber?)?.boolValue,
            intro: b.intro
        )
    }

    // MARK: - 搜索结果消费（防御转换 + 降级 hint 直显，不自己拼文案）
    /// SearchResult → [BookCard]，Views 层不碰 KMP 的 Book 类型
    static func cards(from result: SearchResult?) -> [BookCard] {
        guard let result = result else { return [] }
        return books(from: result).map(card(from:))
    }

    static func books(from result: SearchResult) -> [Book] {
        (result.books as? [Book]) ?? []      // NSArray → [Book] 防御转换
    }
    /// 降级语义：books 空 + source=none + hint 非空 → UI 原样展示 hint
    static func degradedHint(from result: SearchResult) -> String? {
        result.hint
    }

    // MARK: - 集行（Episode v1.1 全字段）
    struct EpisodeRow {
        let title: String
        let trackId: Int64           // extract 的输入（三形态之一：裸 trackId 直通）
        let index: Int32             // 全书序号 1 起，跨页连续
        let durationMs: Int64        // 毫秒；UI 显示需 /1000
        let coverUrl: String
        let url: String              // 上游给的曲目地址；trackId<=0 时作为 extract 回退输入
    }
    /// 壳内自造一行（最近播放/队列续播用）：不经过 KMP，纯 Swift 值类型
    static func episodeRow(title: String, trackId: Int64, index: Int32,
                           durationMs: Int64, coverUrl: String, url: String) -> EpisodeRow {
        EpisodeRow(title: title, trackId: trackId, index: index,
                   durationMs: durationMs, coverUrl: coverUrl, url: url)
    }

    static func row(from e: Episode) -> EpisodeRow {
        EpisodeRow(
            title: e.title,
            trackId: e.trackId,
            index: e.index,
            durationMs: e.durationMs,
            coverUrl: e.coverUrl,
            url: e.url
        )
    }

    /// 补齐集地址（修复「解析失败：不是直链」）。
    /// 线上看到的两种数据形态：
    ///   ① 免登录专辑接口不给 playUrl64 → 集 url 变成网页地址 https://www.ximalaya.com/sound/{id}
    ///   ② 有些集 trackId=0，只剩网页地址
    /// 这两种都拿去给 extract() 就会被判「不是直链」。这里拿 trackId 反向补真直链：
    /// 先用免登录源的 track 接口换一次 playUrl，换不到再让 Player 走 WebView 嗅探。
    static func usableURL(_ ep: EpisodeRow) -> String {
        if ep.url.hasPrefix("http") { return ep.url }
        if ep.trackId > 0 { return "https://www.ximalaya.com/sound/\(ep.trackId)" }
        return ep.url
    }

    /// 视作「需要重新解析」的地址：网页详情页，不是媒体文件
    static func looksLikeWebPage(_ url: String) -> Bool {
        guard url.hasPrefix("http") else { return false }
        let l = url.lowercased()
        if l.contains("/sound/") || l.contains("/album/") || l.contains("/track/") { return true }
        let media = [".mp3", ".m4a", ".aac", ".m4b", ".flac", ".wav", ".ogg"]
        if media.contains(where: { l.contains($0) }) { return false }
        return l.contains("ximalaya.com")
    }

    /// 曲目列表转换（供壳内视图调用，避免视图层直接 import shared）
    static func rows(from detail: BookDetail) -> [EpisodeRow] {
        (detail.episodes as? [Episode])?.map(row(from:)) ?? []
    }

    // MARK: - 真机对接（framework 门面 com.local.audiobook.core.TingshuApp）
    /// 引擎 CookieProvider 的 iOS 实现。
    /// 未登录时 cookie() 返回 nil，引擎走匿名预检、不白发请求。
    /// 放在本文件是因为壳侧只有这里允许 import shared（CookieProvider 协议来自 framework）。
    final class XimalayaCookieProvider: NSObject, CookieProvider {
        private var cached: String?
        private let lock = NSLock()

        func cookie(completionHandler: @escaping (String?, (any Error)?) -> Void) {
            lock.lock()
            if let c = cached { lock.unlock(); completionHandler(c, nil); return }
            lock.unlock()

            let flat = CookieStore.flatMap()
            guard CookieStore.isLoggedIn(flat) else {
                completionHandler(nil, nil)   // 未登录：匿名预检
                return
            }
            let header = flat.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            lock.lock(); cached = header; lock.unlock()
            completionHandler(header, nil)
        }

        func refresh(completionHandler: @escaping ((any Error)?) -> Void) {
            lock.lock(); cached = nil; lock.unlock()
            completionHandler(nil)
        }

        /// 登录完成 / 登出后调用，使下次请求重读 Cookie 存储
        func invalidate() { lock.lock(); cached = nil; lock.unlock() }
    }

    static let cookieProvider = XimalayaCookieProvider()

    /// 全局唯一引擎实例。App 生命周期内复用，限速状态与搜索预算随之保留。
    /// K/N 不保留 Kotlin 默认参数，构造器全参必填。
    static let app: TingshuApp = TingshuApp(cookieProvider: cookieProvider)

    /// K/N 不生成 Swift async 重载，suspend 函数只暴露 completionHandler 形式。
    /// 这里统一包成 async，让视图层能直接 await，同时不把 NSError 桥接细节散到各处。
    private static func bridge<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            body { value, _ in cont.resume(returning: value) }
        }
    }

    /// 带错误透传的 bridge（Swift 席 P0-3）：
    /// 原来 error 被吞成 nil，UI 只能说「取不到播放地址」，
    /// 分不清「需要登录」还是「网络断了」还是「章节下架」。
    @discardableResult
    private static func bridgeWithError<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) async -> (value: T?, error: Error?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(T?, Error?), Never>) in
            body { value, error in cont.resume(returning: (value, error)) }
        }
    }

    /// 当前是否为已登录态（读 HTTPCookieStorage，规则与 Kotlin 侧一致）
    static var loggedIn: Bool { CookieStore.isLoggedInNow }

    /// 登录完成/登出后调用：清引擎侧 cookie 缓存，使下次请求重新读取
    static func invalidateSession() {
        cookieProvider.invalidate()
        injectCookie()      // 登录态变了，重新灌给引擎
    }

    /// 搜索。引擎内部已限速(1/s)+预算(3次/30s)，失败降级返回空书单+hint，不抛。
    ///
    /// 2026-11-24：套 9s 硬超时。原来底层请求超时 32s 会把风控/慢站拖满 32 秒，
    /// 而搜索只要「有没有结果」，超时就当没有，让并发里另外两路接上。
    static func search(keywords: String, page: Int) async -> SearchResult? {
        let call = { await bridge { done in
            app.search(keywords: keywords, page: Int32(page), completionHandler: { res, err in done(res, err) })
        } }
        return await withTimeout(seconds: searchTimeoutSeconds, call)
    }

    /// 浏览器搜索：走 WKWebView 打开喜马拉雅搜索页，抓结构化结果。
    /// 引擎直连会撞风控（riskLevel=5）与 webtk 缺失，这条路绕开这两个门。
    /// 返回空数组表示页面里没找到结果。
    /// 失败时（含 P1-9 的 busy / 超时）把可读原因写进 lastWebSearchError，不再一律吞成「没结果」。
    private static let webErrLock = NSLock()
    private static var _lastWebSearchError: String?
    static var lastWebSearchError: String? {
        get { webErrLock.lock(); defer { webErrLock.unlock() }; return _lastWebSearchError }
        set { webErrLock.lock(); defer { webErrLock.unlock() }; _lastWebSearchError = newValue }
    }

    static func browserSearch(keyword: String, page: Int = 1,
                              timeout: Double = WebSearchBridge.webSoftSeconds) async -> [BookCard] {
        lastWebSearchError = nil
        do {
            let raw = try await WebSearchBridge.shared.search(keyword: keyword, page: page, timeout: timeout)
            return raw.compactMap { dict -> BookCard? in
                guard let id = dict["albumId"] as? String, !id.isEmpty,
                      let title = dict["title"] as? String, !title.isEmpty else { return nil }
                let cover = (dict["cover"] as? String) ?? ""
                return BookCard(
                    bookUrl: "/album/\(id)",
                    title: title,
                    author: (dict["author"] as? String) ?? "",
                    coverUrl: cover.hasPrefix("//") ? "https:" + cover : cover,
                    albumId: Int64(id) ?? 0,
                    trackCount: Int64((dict["trackCount"] as? NSNumber)?.int64Value ?? 0),
                    playCount: Int64((dict["playCount"] as? NSNumber)?.int64Value ?? 0),
                    isFinished: (dict["isFinished"] as? Bool) ?? false
                )
            }
        } catch {
            // P1-9：busy / 超时 / 页面失败各自带明确文案，交给书架原样显示
            let desc = error.localizedDescription
            lastWebSearchError = desc.isEmpty ? String(describing: error) : desc
            return []
        }
    }

    // MARK: - 搜索（并发三路 + 早返回合并 + 缓存）

    /// 搜索总超时（秒）。引擎与网页两路都在这个时间内必须给出交代。
    /// 依据：喜马拉雅 front 接口本机实测 0.4~2.5s；WKWebView 冷启动打开搜索页 3~6s。
    /// 原来 32s(引擎请求) + 20s(WKWebView) 串行 = 最坏 52s，再加 open 兜底 32s ≈ 84s，
    /// 对应用户报的「一分多钟」。
    static let searchTimeoutSeconds: Double = 9

    /// 网页那路的软上限：到点就用已经抓到的部分（可能是 0 条），不阻塞合并
    static let webSoftTimeoutSeconds: Double = 6.5

    /// 内存缓存 TTL 与磁盘缓存 schema（结构变了就 +1，旧缓存自动失效）
    private static let searchCacheTTL: TimeInterval = 5 * 60
    private static let searchCacheSchema = 1
    private static let searchCacheNamespace = "search"

    private struct CachedSearch: Codable {
        var cards: [BookCard]
        var savedAt: Date
    }

    /// 并发三路共用的累加器。TaskGroup 的 addTask 闭包是 @Sendable，
    /// 结果只能往一个带锁的盒子里塞（不能用 var 捕获 —— Swift 6 语言模式会直接报错）。
    private final class SearchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _cards: [BookCard] = []
        private var _reason: String?
        private var _seen = Set<String>()

        var cards: [BookCard] {
            lock.lock(); defer { lock.unlock() }; return _cards
        }

        var reason: String? {
            lock.lock(); defer { lock.unlock() }; return _reason
        }

        func add(_ items: [BookCard]) {
            lock.lock(); defer { lock.unlock() }
            for c in items {
                let key = c.albumId > 0 ? String(c.albumId) : c.bookUrl
                if _seen.insert(key).inserted { _cards.append(c) }
            }
        }

        func note(_ why: String) {
            lock.lock(); defer { lock.unlock() }
            if _reason == nil { _reason = why }
        }
    }

    private static let cacheLock = NSLock()
    private static var memCache: [String: (cards: [BookCard], at: Date)] = [:]

    private static func cacheKey(_ keyword: String, _ page: Int) -> String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "#p" + String(page)
    }

    private static func cachedSearch(_ key: String) -> [BookCard]? {
        cacheLock.lock()
        let hit = memCache[key]
        cacheLock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < searchCacheTTL, !hit.cards.isEmpty {
            return hit.cards
        }
        // 磁盘缓存：跨启动也能命中（内存 5 分钟、磁盘同样 5 分钟，schema=1）
        if let disk = DiskCache.read(CachedSearch.self, schema: searchCacheSchema,
                                     namespace: searchCacheNamespace, key: key, ttl: searchCacheTTL),
           !disk.isStale, !disk.value.cards.isEmpty {
            cacheLock.lock(); memCache[key] = (disk.value.cards, disk.value.savedAt); cacheLock.unlock()
            return disk.value.cards
        }
        return nil
    }

    private static func storeSearch(_ key: String, _ cards: [BookCard]) {
        guard !cards.isEmpty else { return }
        cacheLock.lock(); memCache[key] = (cards, Date()); cacheLock.unlock()
        DiskCache.write(CachedSearch(cards: cards, savedAt: Date()), schema: searchCacheSchema,
                        namespace: searchCacheNamespace, key: key)
    }

    /// 搜索（对外唯一入口，书架调这个）。
    ///
    /// 改造要点（2026-11-24，对应「搜索一分多钟」）：
    ///   ① 命中缓存直接返回（5 分钟内同关键词 + 跨启动磁盘缓存）
    ///   ② 未登录不再跑登录版引擎 / 网页两路（它们必失败，白耗 32s+20s），
    ///      直接走免登录 search.ximalaya.com/front —— 实测这条不受 riskLevel 5 影响
    ///   ③ 已登录时两条路（引擎直连 + WKWebView）真并发，谁先出结果谁先渲染，
    ///      另一路最多再等 searchTimeoutSeconds，到点用已到的部分合并
    ///   ④ 整体套 searchTimeoutSeconds 硬上限，任何一路卡死都不会拖住 UI
    static func searchBoth(keyword: String, page: Int = 1) async -> [BookCard] {
        await searchFast(keyword: keyword, page: page)
    }

    /// 带阶段回调的版本：每路一有结果就回调一次，UI 可以先渲染再追加
    /// （书架用这个；其它调用方用 searchBoth 即可）
    static func searchFast(keyword: String, page: Int = 1,
                           onPartial: (@Sendable ([BookCard]) -> Void)? = nil) async -> [BookCard] {
        lastWebSearchError = nil
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }

        let key = cacheKey(kw, page)
        if let hit = cachedSearch(key) {
            CrashLog.search(kw, path: "cache", ms: 0, count: hit.count)
            return hit
        }

        let t0 = Date()
        let merged: [BookCard]
        if !loggedIn {
            // 未登录：登录版引擎与网页搜索都拿不到东西，跳过（这是原先最慢的一段）
            merged = await searchOpenOnly(keyword: kw, page: page)
        } else {
            merged = await searchConcurrent(keyword: kw, page: page, onPartial: onPartial)
        }
        CrashLog.search(kw, path: loggedIn ? "concurrent" : "open-only",
                        ms: Int(Date().timeIntervalSince(t0) * 1000), count: merged.count)
        if !merged.isEmpty { storeSearch(key, merged) }
        return merged
    }

    /// 已登录：引擎直连 + WKWebView + 免登录 front 三路并发，先到的先用
    private static func searchConcurrent(keyword: String, page: Int,
                                         onPartial: (@Sendable ([BookCard]) -> Void)? = nil) async -> [BookCard] {
        let box = SearchBox()
        await withTaskGroup(of: (String, [BookCard], String?).self) { group in
            group.addTask {
                let t = Date()
                let res = await search(keywords: keyword, page: page)
                let cards = res.map { self.cards(from: $0) } ?? []
                let why = res.flatMap { self.degradedHint(from: $0) }
                CrashLog.search(keyword, path: "engine",
                                ms: Int(Date().timeIntervalSince(t) * 1000), count: cards.count)
                return ("engine", cards, why)
            }
            group.addTask {
                let t = Date()
                let cards = await browserSearch(keyword: keyword, page: page, timeout: webSoftTimeoutSeconds)
                CrashLog.search(keyword, path: "web",
                                ms: Int(Date().timeIntervalSince(t) * 1000), count: cards.count)
                return ("web", cards, lastWebSearchError)
            }
            group.addTask {
                let t = Date()
                let cards = await searchOpenOnly(keyword: keyword, page: page)
                CrashLog.search(keyword, path: "open",
                                ms: Int(Date().timeIntervalSince(t) * 1000), count: cards.count)
                return ("open", cards, nil)
            }

            // 硬上限：到点不管还有几路没回，直接用已合并的结果。
            // 注意：不能在子 Task 里捕获 group（它是 inout 参数，逃逸闭包捕获会编译失败），
            // 所以改成「循环里自己数时间」，超时就 break，剩下交给 cancelAll。
            let startedAt = Date()
            for await (path, cards, why) in group {
                box.add(cards)
                if let why { box.note(path + "：" + why) }
                if !cards.isEmpty, let onPartial { onPartial(box.cards) }   // 早返回：先到的先渲染
                if Date().timeIntervalSince(startedAt) >= searchTimeoutSeconds { break }
            }
            group.cancelAll()
        }
        lastWebSearchError = box.cards.isEmpty ? box.reason : nil
        return box.cards
    }

    /// 未登录（或作为并发中的第三路）：只走免登录 front 接口，8~9s 内必有交代
    private static func searchOpenOnly(keyword: String, page: Int) async -> [BookCard] {
        let res = await withTimeout(seconds: searchTimeoutSeconds) {
            await search(sourceId: "ximalaya-open", keywords: keyword, page: page)
        }
        guard let res else { return [] }
        let cards = cards(from: res)
        if cards.isEmpty, let h = degradedHint(from: res) { lastWebSearchError = "免登录源：" + h }
        return cards
    }

    /// 给任意 async 调用套一个硬超时（超时返回 nil，不抛）
    private static func withTimeout<T>(seconds: Double, _ op: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 专辑详情 + 曲目。失败返回 nil。
    static func bookDetail(bookUrl: String) async -> BookDetail? {
        let r = await bridge { (done: @escaping (SourceRegistry.BookDetailResult?, Error?) -> Void) in
            app.bookDetailSafe(bookUrl: bookUrl, loadEpisodes: true, loadFullPages: false,
                               completionHandler: { res, err in done(res, err) })
        }
        lastDetailError = r?.reason
        return r?.detail
    }

    /// 取播放地址（级1→级3 提取链）。
    static func extract(url: String) async -> ExtractedAudio? {
        let r = await bridge { (done: @escaping (SourceRegistry.AudioResult?, Error?) -> Void) in
            app.extractSafe(url: url, timeoutMs: 15_000, completionHandler: { res, err in done(res, err) })
        }
        if let r, r.audio == nil { lastAudioError = r.reason }
        return r?.audio
    }

    /// 解析专辑 ID（/album/{id}、?albumId=、纯数字 ≥4 位）。同步函数，K/N 直接导出。
    static func albumId(from bookUrl: String) -> Int64 {
        app.parseAlbumId(bookUrl: bookUrl)
    }

    /// 播放地址时效展示（M3 最小用例可直接读）
    static func expiresText(from a: ExtractedAudio) -> String? {
        a.expiresInSeconds > 0 ? "地址有效 \(a.expiresInSeconds / 60) 分钟" : nil
    }

    // MARK: - 错误族 → 壳侧文案（is 链匹配；RateLimited = 不硬冲语义）
    static func message(for error: SourceErrors) -> String {
        if error is SourceErrors.NotFound { return "没有找到该资源" }
        if error is SourceErrors.ParseFailed { return "解析失败" }
        if error is SourceErrors.RateLimited { return "触发限流，稍后再试，不硬冲" }
        if let e = error as? SourceErrors.Network { return "网络异常：" + e.reason }  // v1.1: cause→reason
        if error is SourceErrors.Auth { return "登录态失效，请重新登录" }
        if let e = error as? SourceErrors.Vip { return e.reason }
        if error is SourceErrors.Upstream { return "上游服务异常" }
        return "未知错误"
    }

    // ==================== 源管理（SourceRegistry） ====================

    /// 全局源注册表（38 个源：5 原生 + 1 登录版 + 32 模板站）
    static let registry: SourceRegistry = {
        let r = SourceRegistryFactory().registry()
        // 启动即注入真实登录态（装机反馈：之前永远 null，导致登录版必报「需要登录」）
        injectCookie()
        return r
    }()

    /// 把 HTTPCookieStorage 里的喜马拉雅 Cookie 灌进引擎。
    /// 登录成功、登出、启动时都要调。
    static func injectCookie() {
        let cookies = CookieStore.ximalayaCookies()
        guard !cookies.isEmpty else {
            SourceRegistryFactory().setCookie(cookie: nil)
            cookieProvider.invalidate()
            return
        }
        // 拼成 "k=v; k2=v2" 形式
        let header = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
        SourceRegistryFactory().setCookie(cookie: header)
        // 两套缓存都要失效：工厂的 injectedCookie 与 provider 的 cached 各自独立，
        // 只刷一个会出现「设置页显示已同步 355 字符，引擎照样报未登录」
        cookieProvider.invalidate()
    }

    /// 供设置页显示：引擎当前拿到的 Cookie 长度（0 = 没注入）
    static var engineCookieLength: Int {
        Int(SourceRegistryFactory().currentCookieLength())
    }

    /// 源描述（纯 Swift 类型，UI 层不碰 KMP 类型）
    struct SourceItem: Identifiable, Hashable {
        let id: String
        let name: String
        let desc: String
        /// "native" / "template" / "login"
        let kind: String
    }

    /// 源清单（给 UI 列表用）
    static func allSources() -> [SourceItem] {
        registry.list().map { info in
            SourceItem(
                id: info.id,
                name: info.name,
                desc: info.desc,
                kind: info.kind,
            )
        }
    }

    /// 按源搜索
    static func search(sourceId: String, keywords: String, page: Int) async -> SearchResult? {
        let call: () async -> SearchResult? = {
            await bridge { (done: @escaping (SearchResult?, Error?) -> Void) in
                registry.search(sourceId: sourceId, keywords: keywords, page: Int32(page),
                                completionHandler: { r, e in
                    if e != nil { done(nil, e) } else { done(r, nil) }
                })
            }
        }
        // 同样套 9s 硬上限：模板站慢站（aj006 实测 29.8s）不该拖住搜索
        return await withTimeout(seconds: searchTimeoutSeconds, call)
    }

    /// 按源详情。Kotlin 侧返回 BookDetailResult，失败时 reason 非空。
    /// 上一次取专辑详情的失败原因（UI 要显示「为什么没出来」，不能只给一句「加载失败」）
    private static let detailErrLock = NSLock()
    private static var _lastDetailError: String?
    static var lastDetailError: String? {
        get { detailErrLock.lock(); defer { detailErrLock.unlock() }; return _lastDetailError }
        set { detailErrLock.lock(); defer { detailErrLock.unlock() }; _lastDetailError = newValue }
    }

    static func bookDetail(sourceId: String, bookUrl: String) async -> BookDetail? {
        lastDetailError = nil
        if let d = await rawBookDetail(sourceId: sourceId, bookUrl: bookUrl) { return d }
        let firstReason = lastDetailError

        // 兜底 1：喜马拉雅登录版失败（Cookie 过期/风控）→ 换免登录版同一专辑
        if sourceId == "ximalaya", bookUrl.contains("/album/") {
            if let d = await rawBookDetail(sourceId: "ximalaya-open", bookUrl: bookUrl) {
                lastDetailError = nil
                return d
            }
        }
        // 兜底 2：书是酷我/B站等别的源搜出来的，专辑地址却是网页地址 → 试一次模板/原生解析
        lastDetailError = firstReason
        return nil
    }

    private static func rawBookDetail(sourceId: String, bookUrl: String) async -> BookDetail? {
        let r = await bridge { done in
            registry.bookDetail(sourceId: sourceId, bookUrl: bookUrl, loadEpisodes: true,
                                completionHandler: { res, e in done(res, e) })
        }
        guard let r = r else { return nil }
        if let d = r.detail { return d }
        lastDetailError = r.reason
        return nil
    }

    /// 上一次取播放地址的失败原因（P0-3：让「需要登录」能区分于「网络断了」）。
    /// Player 在 audio() 返回 nil 后读它，把真实原因显示给用户。
    /// 跨线程读写（回调线程写、@MainActor 读），用锁保护。
    /// Swift 5 语言模式下不用 nonisolated(unsafe)（那是 5.10+ 才有）。
    private static let audioErrLock = NSLock()
    private static var _lastAudioError: String?
    static var lastAudioError: String? {
        get { audioErrLock.lock(); defer { audioErrLock.unlock() }; return _lastAudioError }
        set { audioErrLock.lock(); defer { audioErrLock.unlock() }; _lastAudioError = newValue }
    }

    /// 按源取播放地址。失败返回 nil，同时把可读原因记进 lastAudioError。
    /// K/N  fatal 防护：Kotlin 侧现在返回 AudioResult，不再抛异常给 Swift。
    static func audio(sourceId: String, url: String) async -> ExtractedAudio? {
        lastAudioError = nil
        let r = await bridge { done in
            registry.audio(sourceId: sourceId, url: url, completionHandler: { res, e in
                done(res, e)
            })
        }
        guard let r = r else { return nil }
        if let reason = r.reason {
            Self.lastAudioError = reason
            return nil
        }
        return r.audio
    }

    /// 模板站分类浏览
    static func categoryBooks(sourceId: String, catIndex: Int) async -> [Book] {
        let r = await bridge { done in
            registry.categoryBooks(sourceId: sourceId, catIndex: Int32(catIndex),
                                   completionHandler: { list, e in done(list, e) })
        }
        return r ?? []
    }

    /// 模板站分类名列表
    static func categories(sourceId: String) -> [(String, String)] {
        registry.categories(sourceId: sourceId).map { (String(describing: $0.first ?? ""), String(describing: $0.second ?? "")) }
    }


    // ==================== WebView 嗅探（JS 渲染站兜底） ====================

    /// 引擎拿不到直链时的最后一级：用 WKWebView 打开播放页，
    /// 五路 hook 抓真实媒体 URL（vbus / ting15 这类 JS 渲染站靠它）。
    /// 失败返回 nil，不猜地址。
    static func sniffAudio(pageUrl: String, timeoutMs: Int = 20_000) async -> String? {
        do {
            return try await WebViewSniffer.shared.sniff(url: pageUrl, timeoutMs: timeoutMs)
        } catch {
            return nil
        }
    }


    /// 构造一个只有 URL 的 ExtractedAudio（嗅探兜底用）
    static func makeAudio(url: String) -> ExtractedAudio? {
        ExtractedAudio(url: url, headers: [:], expiresInSeconds: 0)
    }

    /// 兜底 UA：模板站/嗅探出来的直链经常「裸请求 403」，带一个桌面 UA 就能过。
    /// 只在引擎没给 User-Agent 时补，绝不覆盖引擎已经算好的那个。
    static let fallbackUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 给一份 headers 补上缺省的 UA（返回新字典）
    static func withDefaultUA(_ headers: [String: String]) -> [String: String] {
        if headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { return headers }
        var h = headers
        h["User-Agent"] = fallbackUA
        return h
    }

}
