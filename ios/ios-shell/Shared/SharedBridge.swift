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
        /// 【P0 v1.4.7】这条搜索结果来自哪个源。
        ///
        /// 之前没有这个字段 —— 搜索结果从三路（引擎/网页/免登录）合并而来，来源当场丢失，
        /// 于是 ShelfView 只能猜「登录了就是 ximalaya」。结果：任何非喜马拉雅的书
        /// （模板站、懒人、酷我、网易云、B站…）都会用喜马拉雅的解析器去拿详情和播放地址，
        /// 必然失败。表现就是「推荐的书能播，自己搜的书播不了」——
        /// 推荐页自带 sourceId，搜索页把它猜成 ximalaya 了。
        /// 旧缓存里没有这个键，必须 decodeIfPresent 兜底成空串。
        var sourceId: String = ""

        /// 上游给的**相关度序号**，用来在多路结果合并后保住原来的搜索排序。
        /// 99 = 没有 rank（网页抓取/兜底），排在有 rank 的后面。
        var rank: Int32 = 99

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
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
            rank = try c.decodeIfPresent(Int32.self, forKey: .rank) ?? 99
        }

        init(bookUrl: String, title: String, author: String, coverUrl: String,
             albumId: Int64, trackCount: Int64, playCount: Int64, isFinished: Bool?,
             intro: String = "", sourceId: String = "", rank: Int32 = 99) {
            self.bookUrl = bookUrl; self.title = title; self.author = author
            self.coverUrl = coverUrl; self.albumId = albumId
            self.trackCount = trackCount; self.playCount = playCount
            self.isFinished = isFinished; self.intro = intro; self.sourceId = sourceId
            self.rank = rank
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
            intro: b.intro,
            // K/N 导出的 Book 自带 sourceId（Kotlin 侧每条结果都填了来源）。
            // 这里是唯一读它的地方，其它调用方走 card(from:defaultSource:) 补默认值。
            sourceId: b.sourceId
        )
    }

    /// card(from:) 的带源版本：Known 来源优先用 Book 自带的，Book 没带就用参数。
    static func cards(from result: SearchResult?, defaultSource: String) -> [BookCard] {
        guard let result = result else { return [] }
        // 保序：给每条打上它在本次搜索里的名次。
        // 三路并发谁先回来不定，但**每一路内部**的顺序是上游算好的相关度，不能丢。
        return books(from: result).enumerated().map { idx, b in
            var c = card(from: b, defaultSource: defaultSource)
            if c.rank == 99 { c.rank = Int32(idx) }
            return c
        }
    }

    static func card(from b: Book, defaultSource: String) -> BookCard {
        var c = card(from: b)
        if c.sourceId.isEmpty { c.sourceId = defaultSource }
        return c
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
        let url: String              // 音频直链；**空串 = 本集没有直链**（VIP/付费/已下架）
        /// 本集能不能直接播。false 时 hint 一定非空。
        ///
        /// 2026-11-25：这是「搜出来的书播不了」的正面解。
        /// 喜马 VIP 轨在 mobwsa 里 playUrl64=""、isPaid=true，旧引擎拿 /sound/{id} 网页顶上，
        /// 播放器出口闸拦下后只报「只给了网页地址」，用户看不出是要钱。
        /// 现在引擎直接告诉我们「这集不能播 + 为什么」，UI 和播放器都不用瞎猜。
        let playable: Bool
        let hint: String

        init(title: String, trackId: Int64, index: Int32, durationMs: Int64,
             coverUrl: String, url: String, playable: Bool = true, hint: String = "") {
            self.title = title
            self.trackId = trackId
            self.index = index
            self.durationMs = durationMs
            self.coverUrl = coverUrl
            self.url = url
            self.playable = playable
            self.hint = hint
        }
    }
    /// 壳内自造一行（最近播放/队列续播用）：不经过 KMP，纯 Swift 值类型
    static func episodeRow(title: String, trackId: Int64, index: Int32,
                           durationMs: Int64, coverUrl: String, url: String,
                           playable: Bool = true, hint: String = "") -> EpisodeRow {
        EpisodeRow(title: title, trackId: trackId, index: index,
                   durationMs: durationMs, coverUrl: coverUrl, url: url,
                   playable: playable, hint: hint)
    }

    static func row(from e: Episode) -> EpisodeRow {
        EpisodeRow(
            title: e.title,
            trackId: e.trackId,
            index: e.index,
            durationMs: e.durationMs,
            coverUrl: e.coverUrl,
            url: e.url,
            playable: e.playable,
            hint: e.hint
        )
    }

    /// 补齐集地址（修复「解析失败：不是直链」）。
    /// 线上看到的两种数据形态：
    ///   ① 免登录专辑接口不给 playUrl64 → 集 url 变成网页地址 https://www.ximalaya.com/sound/{id}
    ///   ② 有些集 trackId=0，只剩网页地址
    /// 这两种都拿去给 extract() 就会被判「不是直链」。这里拿 trackId 反向补真直链：
    /// 先用免登录源的 track 接口换一次 playUrl，换不到再让 Player 走 WebView 嗅探。

    /// 视作「需要重新解析」的地址：网页详情页，不是媒体文件。
    ///
    /// 【2026-11-27 P0 真机复现】原来的实现是「只要是 ximalaya.com 就判网页」，
    /// 于是客户端通道返回的 `http://mobile.ximalaya.com/mobile/redirect/free/play/{id}/1`
    /// 被判成网页，Player 的第二道闸直接拒播，报「源站只给了网页地址」——
    /// 而那个地址 302 之后就是 audiopay CDN 的 .m4a，是真正的音频。
    ///
    /// 现在改成**正向判定页面路径**（/sound/ /album/ /track/ /show/），而不是「是这个域就算页面」。
    /// 另外把中转型路径（/redirect /play/ /stream/ /get-source/）显式放行。
    static func looksLikeWebPage(_ url: String) -> Bool {
        guard url.hasPrefix("http") else { return false }
        let l = url.lowercased()
        // 中转型直链：无扩展名但 302 到音频，必须先放行（否则蜻蜓/酷我/喜马 redirect 全挂）
        let relayMarks = ["/redirect", "/play/", "/stream/", "/get-source/", "/meting/",
                          "/audiostream/", "/program/get-source/"]
        if relayMarks.contains(where: { l.contains($0) }) { return false }
        // 音频扩展名：直接判音频
        let media = [".mp3", ".m4a", ".m4s", ".m4b", ".aac", ".flac", ".wav", ".ogg", ".opus"]
        if media.contains(where: { l.contains($0) }) { return false }
        // 只有这些**页面路径**才是网页
        let pagePaths = ["/sound/", "/album/", "/track/", "/show/", "/xiangqing/", "/zhubo/"]
        if pagePaths.contains(where: { l.contains($0) }) { return true }
        // 其余 http 地址一律不当网页：宁可让 AVPlayer 去试，也别把真音频拦掉。
        // （真错了会得到 -12847，那时再针对性加规则，而不是提前一刀切。）
        return false
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
            var rank: Int32 = 0
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
                    isFinished: (dict["isFinished"] as? Bool) ?? false,
                    // 网页搜索抓的是喜马拉雅页面 → 来源是登录通道
                    sourceId: "ximalaya",
                    rank: { defer { rank += 1 }; return rank }()
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
    // v1.4.7：BookCard 新增 sourceId。旧缓存里的搜索结果没有来源，
    // 反序列化后是空串 → sourceOf 回退成「猜 ximalaya」→ 非喜马拉雅的书又播不了。
    // 所以把 schema 升到 2，旧搜索结果直接失效重搜。
    private static let searchCacheSchema = 3
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
        /// 键 -> 在 _cards 里的下标（合并需要定位，不能只存 seen 集合）
        private var _indexByKey: [String: Int] = [:]

        var cards: [BookCard] {
            lock.lock(); defer { lock.unlock() }
            // 按各源自带的相关度 rank 排序（同一路内保持原顺序）。
            // 没有 rank 的（网页搜索抓来的）排在后面，但它们之间仍保持抓取顺序。
            return _cards.enumerated().sorted { lhs, rhs in
                let lr = lhs.element.rank, rr = rhs.element.rank
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }.map { $0.element }
        }

        var reason: String? {
            lock.lock(); defer { lock.unlock() }; return _reason
        }

        /// 去重 + **合并**（不是丢弃）。
        ///
        /// 2026-11-25：以前键是 sourceId:albumId，而 engine 路给的是 "ximalaya"、
        /// open 路给的是 "ximalaya-open" —— 同一本喜马书出两行，用户看到重复结果。
        /// 现在把两个喜马源归一成 "ximalaya" 作为身份，然后按「登录态适用性」择优保留：
        /// 登录了留登录通道的卡（能取会员集），未登录留免登录的卡（否则点进去要登录）。
        /// 并发三路到达顺序不定，所以不能「先到先赢」。
        /// 每路结果的插入序号。并发三路谁先回来不确定，但界面上的顺序不能因此乱跳。
        /// 2026-11-25：用户搜「在暴雪时分」，官方那条（1510 万播放、VIP 剧场）排在第 8 位
        /// —— 因为它是 open 路第 8 条，而这次 engine 路先回来把前 7 个位置占了。
        /// 换成 engine 先超时，那本书就会跑到最前面。顺序不稳定 = 用户找不到。
        private var lastRank: Int32 = .max

        func add(_ items: [BookCard]) {
            lock.lock(); defer { lock.unlock() }
            let preferLogin = SharedBridge.loggedIn
            for c in items {
                let src = Self.identitySource(c.sourceId)
                let idPart = c.albumId > 0 ? String(c.albumId) : c.bookUrl
                let key = src + ":" + idPart
                if let idx = _indexByKey[key] {
                    if Self.richer(c, than: _cards[idx], preferLogin: preferLogin) {
                        _cards[idx] = c
                    }
                } else {
                    _indexByKey[key] = _cards.count
                    _cards.append(c)
                }
            }
        }

        /// 身份用源：两个喜马通道视为同一个源，其它源保持原样
        private static func identitySource(_ sourceId: String) -> String {
            switch sourceId {
            case "ximalaya", "ximalaya-open": return "ximalaya"
            case "": return "-"
            default: return sourceId
            }
        }

        /// 同一本书的两个候选，留哪个：先看登录态适用性，再看信息完整度
        private static func richer(_ candidate: BookCard, than existing: BookCard,
                                   preferLogin: Bool) -> Bool {
            let wanted = preferLogin ? "ximalaya" : "ximalaya-open"
            let candOK = candidate.sourceId == wanted
            let existOK = existing.sourceId == wanted
            if candOK != existOK { return candOK }
            func score(_ c: BookCard) -> Int {
                var n = 0
                if !c.author.isEmpty { n += 1 }
                if !c.coverUrl.isEmpty { n += 1 }
                if !c.intro.isEmpty { n += 1 }
                if c.trackCount > 0 { n += 1 }
                if c.playCount > 0 { n += 1 }
                return n
            }
            return score(candidate) > score(existing)
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
                let cards = res.map { self.cards(from: $0, defaultSource: "ximalaya") } ?? []
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
        let cards = cards(from: res, defaultSource: "ximalaya-open")
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
    /// 注册「引擎要求重读登录态」的回调。
    /// 引擎在遇到 need_login 时会调 CookieProvider.refresh()，
    /// 以前那个实现是空的，所以 Cookie 过期后同一进程内永远恢复不了。
    private static var refreshHookInstalled = false
    static func installRefreshHookOnce() {
        guard !refreshHookInstalled else { return }
        refreshHookInstalled = true
        SourceRegistryFactory().setRefreshHook(hook: {
            injectCookie()
        })
    }

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

    // MARK: - 取消令牌（跨 K/N 桥传递）

    /// Kotlin 的 CancelToken 实现。
    /// SwiftUI 取消 .task 只会丢弃 await 的挂起点，**传不到 Kotlin 协程** ——
    /// 那个协程会继续翻完 40 页、占着全局 1 秒/次的限速队列，
    /// 用户返回后点别的书、点播放取地址都要排队。这个对象是唯一能过桥的信号。
    final class CancelFlag: NSObject, CancelToken {
        private let lock = NSLock()
        private var _cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            _cancelled = true
        }
    }

    // MARK: - 会员状态（接口优先，WebView 兜底）

    /// 会员状态。**先问接口**（`/revision/main/getCurrentUser` + `/revision/user/basic`），
    /// 只有接口全拿不到时才让调用方去开 WebView。
    ///
    /// 2026-11-25 修：以前「我的」页直接开 WKWebView 读 https://www.ximalaya.com/vip 的 innerText，
    /// 而那个页面每个用户（含未登录）导航栏都有「开通会员」，旧的 parse 把「会员」二字当命中级联到
    /// .standard —— 没开 VIP 的号也会显示绿勾「会员已开通」。接口这条路本来就写好了，只是没接上。
    static func vipStatus() async -> (tier: String, expire: String, nickname: String, source: String) {
        let r = await bridge { done in
            app.vipStatusSafe(completionHandler: { res, e in done(res, e) })
        }
        guard let r = r else { return ("unknown", "", "", "bridge") }
        return (vipTierName(r.tier), r.expireDate, r.nickname, r.source)
    }

    /// K/N 的 VipTier 是 enum，导出成 ObjC 类；这里用名称映射，避免依赖具体导出符号。
    private static func vipTierName(_ t: shared.VipTier) -> String {
        let s = String(describing: t).lowercased()
        if s.contains("notloggedin") { return "notLoggedIn" }
        if s.contains("normal") { return "standard" }
        if s.contains("none") { return "none" }
        return "unknown"
    }

    /// 源清单（给 UI 列表用）
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

    static func bookDetail(sourceId: String, bookUrl: String,
                           loadFullPages: Bool = true,
                           cancel: CancelFlag? = nil) async -> BookDetail? {
        lastDetailError = nil
        if let d = await rawBookDetail(sourceId: sourceId, bookUrl: bookUrl, loadFullPages: loadFullPages, cancel: cancel) {
            // 【2026-11-25 修语义】上一版这里直接 return，于是「详情取到了但一条都播不了」
            // 的免登录结果被当成成功返回，1b 那段永远跑不到（它的触发条件是「取详情失败」）。
            // 现在：免登录通道成功但**全不可播**且用户已登录时，换登录通道再取一次；
            // 登录通道拿到的可播集更多才采用，否则还回原来那份（至少还有书名/封面/章节列表）。
            if sourceId == "ximalaya-open", bookUrl.contains("/album/"), loggedIn {
                let rows = (d.episodes as? [Episode]) ?? []
                let anyPlayable = rows.contains(where: { $0.playable })
                if !anyPlayable, let login = await rawBookDetail(sourceId: "ximalaya", bookUrl: bookUrl, cancel: cancel) {
                    let loginRows = (login.episodes as? [Episode]) ?? []
                    if loginRows.contains(where: { $0.playable }) {
                        lastDetailError = nil
                        return login
                    }
                }
            }
            return d
        }
        let firstReason = lastDetailError

        // 兜底 1：喜马拉雅登录版失败（Cookie 过期/风控）→ 换免登录版同一专辑
        if sourceId == "ximalaya", bookUrl.contains("/album/") {
            if let d = await rawBookDetail(sourceId: "ximalaya-open", bookUrl: bookUrl, cancel: cancel) {
                lastDetailError = nil
                return d
            }
        }
        // 兜底 2：书是酷我/B站等别的源搜出来的，专辑地址却是网页地址 → 试一次模板/原生解析
        lastDetailError = firstReason
        return nil
    }

    private static func rawBookDetail(sourceId: String, bookUrl: String,
                                     loadFullPages: Bool = true,
                                     cancel: CancelFlag? = nil) async -> BookDetail? {
        let r = await bridge { done in
            registry.bookDetail(sourceId: sourceId, bookUrl: bookUrl, loadEpisodes: true, loadFullPages: loadFullPages,
                               cancel: cancel ?? CancelFlag(),
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
    /// 取地址**并**返回失败原因，一次调用内自洽。
    ///
    /// 2026-11-25 修竞态：以前失败原因写在静态 `lastAudioError` 里，
    /// 而 `audio()` 入口会把它清空。用户连点两集时，B 的入口清空会擦掉 A 刚写入的原因，
    /// A 的报错就退化成一句兜底废话。改成随返回值一起带出来，谁的原因谁负责。
    static func audioEx(sourceId: String, url: String) async -> (audio: ExtractedAudio?, reason: String?) {
        let r = await bridge { done in
            registry.audio(sourceId: sourceId, url: url, completionHandler: { res, e in done(res, e) })
        }
        guard let r = r else { return (nil, "引擎无响应") }
        if let reason = r.reason { return (nil, reason) }
        return (r.audio, nil)
    }

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

    /// 复制一份 ExtractedAudio 并补上缺省 UA。
    /// 不能让调用方直接写 SharedBridge.ExtractedAudio(...)：那是 framework 里
    /// shared 模块顶层的类型，只有本文件（唯一 import shared 的文件）能看见；
    /// Views/Engine 层写全名会报 type 'SharedBridge' has no member 'ExtractedAudio'（已在 CI 实测）。
    static func audioWithDefaultUA(_ a: ExtractedAudio) -> ExtractedAudio {
        ExtractedAudio(url: a.url, headers: withDefaultUA(a.headers),
                       expiresInSeconds: a.expiresInSeconds)
    }

    /// 给一份 headers 补上缺省的 UA（返回新字典）
    static func withDefaultUA(_ headers: [String: String]) -> [String: String] {
        if headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { return headers }
        var h = headers
        h["User-Agent"] = fallbackUA
        return h
    }

}
