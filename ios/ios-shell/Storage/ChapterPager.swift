import Foundation

/// 章节分页元信息（对标摸鱼听书的 chapters/{id}/meta.json）。
/// 为什么需要：4820 集的专辑一次性 rows(from:) 全进内存，详情页会卡 3-8 秒。
/// 这里只记「哪几页有缓存、每页何时更新、某集在第几页」，滚动到边界再拉下一页。
struct ChapterPageMeta: Codable {
    /// 对应 BookKey.id
    let albumKey: String
    /// 总集数（上游给的 trackCount，没有就 0，按已加载推断）
    var total: Int = 0
    /// 每页集数
    var pageSize: Int = 50
    /// 已缓存的页码
    var pages: Set<Int> = []
    /// 每页最后更新时间
    var pageUpdatedAt: [Int: Date] = [:]
    /// trackId → 页码反查表（用于「跳到第 N 集」直接定位）
    var trackPages: [String: Int] = [:]
    /// 缓存代号：引擎换解析规则时 +1，旧缓存自动作废
    var generation: Int = 1

    func isStale(_ page: Int, ttl: TimeInterval = 7 * 24 * 3600) -> Bool {
        guard let at = pageUpdatedAt[page] else { return true }
        return Date().timeIntervalSince(at) > ttl
    }

    /// 某集在哪一页；找不到返回 nil（调用方回退全量拉）
    func page(ofTrack trackId: Int64) -> Int? {
        trackPages[String(trackId)]
    }
}

/// 分页缓存的落盘层。键 = BookKey.id
enum ChapterPager {
    /// 旧版**单键全局 map** 的键名，只用来做一次性迁移
    private static let legacyKey = "chapterPageMeta.v1"
    /// 新键前缀：每本书一个独立键
    private static let perBookPrefix = "chapterPageMeta.v2."
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // 【2026-11-25 P1 修扩展性】
    // 旧实现把所有书的分页元数据塞进**一个** UserDefaults 键：
    //   每次翻页 = loadAll() 解码全部书 + 改一本 + 编码全部书 + plist 全量重写。
    // 一本 5546 集的书 ≈ 90KB（trackId→页码 表）；20 本大书就是 1.8MB 单键，
    // 而 recordPage 在 MainActor 上调用 —— 滚完一本 111 页累计 2-5 秒主线程卡顿，随书数线性恶化。
    // 现在按 albumKey 拆键：recordPage 只编解码这一本，其它书完全不碰。

    private static func key(for albumKey: String) -> String {
        perBookPrefix + albumKey
    }

    static func loadAll() -> [String: ChapterPageMeta] {
        migrateLegacyIfNeeded()
        var out: [String: ChapterPageMeta] = [:]
        let prefix = perBookPrefix
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            if let data = UserDefaults.standard.data(forKey: k),
               let m = try? decoder.decode(ChapterPageMeta.self, from: data) {
                out[m.albumKey] = m
            }
        }
        return out
    }

    static func meta(for albumKey: String) -> ChapterPageMeta? {
        migrateLegacyIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: key(for: albumKey)) else { return nil }
        return try? decoder.decode(ChapterPageMeta.self, from: data)
    }

    static func save(_ meta: ChapterPageMeta) {
        if let data = try? encoder.encode(meta) {
            UserDefaults.standard.set(data, forKey: key(for: meta.albumKey))
        }
    }

    /// 旧版单键 map → 每本一个键。只跑一次，跑完把旧键删掉。
    private static var migrated = false
    private static func migrateLegacyIfNeeded() {
        guard !migrated else { return }
        migrated = true
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let map = try? decoder.decode([String: ChapterPageMeta].self, from: data) else { return }
        for (k, m) in map {
            if let d = try? encoder.encode(m) {
                UserDefaults.standard.set(d, forKey: perBookPrefix + k)
            }
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    /// 记录一页已加载：更新页码、时间、trackId 反查表
    static func recordPage(_ page: Int,
                           episodes: [SharedBridge.EpisodeRow],
                           albumKey: String,
                           total: Int,
                           pageSize: Int) {
        var m = meta(for: albumKey) ?? ChapterPageMeta(albumKey: albumKey, pageSize: pageSize)
        m.pageSize = pageSize
        if total > 0 { m.total = total }
        m.pages.insert(page)
        m.pageUpdatedAt[page] = Date()
        for ep in episodes {
            if ep.trackId > 0 { m.trackPages[String(ep.trackId)] = page }
        }
        save(m)
    }

    /// 首屏大小与首屏切片；空列表保持空，pageSize 始终为正。
    static func firstPageSize(totalCount: Int, requested: Int = 50) -> Int {
        guard totalCount > 0 else { return 20 }
        // 【2026-11-25】以前「共 N 集」显示的是 totalChapters（取自 book.trackCount），
        // 而首屏切片只有 50 条，页头写「共 50 集」+ 下面却列不完 —— 两个数字各自为政。
        // 现在首屏直接把整本切出来（最多 200 条，超过才分页）：
        // 一本书 67 集、200 集都很常见，一次性进 List 不吃内存；
        // 真正的大部头（4800 集）仍然走分页，行为不变。
        if totalCount <= 200 { return totalCount }
        return max(1, min(max(1, requested), totalCount))
    }

    static func firstPage<Element>(_ all: [Element], requested: Int = 50) -> [Element] {
        Array(all.prefix(firstPageSize(totalCount: all.count, requested: requested)))
    }

    /// 页码从 1 开始；空页与越界页返回 nil，不构造非法范围。
    static func page<Element>(_ all: [Element], number: Int, pageSize: Int) -> [Element]? {
        guard number > 0, pageSize > 0 else { return nil }
        let (start, overflow) = (number - 1).multipliedReportingOverflow(by: pageSize)
        guard !overflow, start >= 0, start < all.count else { return nil }
        return Array(all[start..<min(start + pageSize, all.count)])
    }

    /// 清某本书的分页缓存（下拉刷新时用）
    static func clear(albumKey: String) {
        UserDefaults.standard.removeObject(forKey: key(for: albumKey))
    }

    static func clearAll() {
        let prefix = perBookPrefix
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
