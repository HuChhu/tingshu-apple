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
    struct BookCard {
        let bookUrl: String
        let title: String
        let author: String
        let coverUrl: String
        let albumId: Int64          // 数值专辑 ID，直拼 URL 免正则
        let trackCount: Int64       // 总集数（书架角标）
        let playCount: Int64        // 播放量（「2887万播放」）
        let isFinished: Bool?       // nil = 上游未给，UI 不渲染
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
            isFinished: (b.isFinished as NSNumber?)?.boolValue
        )
    }

    // MARK: - 搜索结果消费（防御转换 + 降级 hint 直显，不自己拼文案）
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
    static func invalidateSession() { cookieProvider.invalidate() }

    /// 搜索。引擎内部已限速(1/s)+预算(3次/30s)，失败降级返回空书单+hint，不抛。
    static func search(keywords: String, page: Int) async -> SearchResult? {
        await bridge { done in
            app.search(keywords: keywords, page: Int32(page), completionHandler: { res, err in done(res, err) })
        }
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

    static func browserSearch(keyword: String, page: Int = 1) async -> [BookCard] {
        lastWebSearchError = nil
        do {
            let raw = try await WebSearchBridge.shared.search(keyword: keyword, page: page)
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

    /// 专辑详情 + 曲目。失败返回 nil。
    static func bookDetail(bookUrl: String) async -> BookDetail? {
        await bridge { done in
            app.bookDetail(bookUrl: bookUrl, loadEpisodes: true, loadFullPages: false,
                           completionHandler: { d, err in done(d, err) })
        }
    }

    /// 取播放地址（级1→级3 提取链）。
    static func extract(url: String) async -> ExtractedAudio? {
        await bridge { done in
            app.extract(url: url, timeoutMs: 15_000, completionHandler: { a, err in done(a, err) })
        }
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
        if error is SourceErrors.Upstream { return "上游服务异常" }
        return "未知错误"
    }

    // ==================== 源管理（SourceRegistry） ====================

    /// 全局源注册表（38 个源：5 原生 + 1 登录版 + 32 模板站）
    static let registry: SourceRegistry = SourceRegistryFactory().registry()

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
        await bridge { done in
            registry.search(sourceId: sourceId, keywords: keywords, page: Int32(page),
                            completionHandler: { r, e in
                if e != nil { done(nil, e) } else { done(r, nil) }
            })
        }
    }

    /// 按源详情
    static func bookDetail(sourceId: String, bookUrl: String) async -> BookDetail? {
        await bridge { done in
            registry.bookDetail(sourceId: sourceId, bookUrl: bookUrl, loadEpisodes: true,
                                completionHandler: { d, e in
                if e != nil { done(nil, e) } else { done(d, nil) }
            })
        }
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
    static func audio(sourceId: String, url: String) async -> ExtractedAudio? {
        lastAudioError = nil
        let result: ExtractedAudio? = await bridge { done in
            registry.audio(sourceId: sourceId, url: url, completionHandler: { a, e in
                if let a = a {
                    done(a, nil)
                } else {
                    // K/N 桥：Kotlin 异常 → NSError(domain: "KotlinException")
                    // 尝试按 SourceErrors 细分；不行就取 localizedDescription 兜底
                    var reason = "未知错误"
                    if let ke = e as? SourceErrors {
                        reason = Self.message(for: ke)
                    } else if let ns = e as? NSError {
                        reason = ns.localizedDescription.isEmpty ? "未知错误" : ns.localizedDescription
                    }
                    Self.lastAudioError = reason
                    done(nil, e)
                }
            })
        }
        return result
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

}
