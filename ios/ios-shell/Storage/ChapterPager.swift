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
    private static let key = "chapterPageMeta.v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func loadAll() -> [String: ChapterPageMeta] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? decoder.decode([String: ChapterPageMeta].self, from: data) else { return [:] }
        return map
    }

    static func meta(for albumKey: String) -> ChapterPageMeta? {
        loadAll()[albumKey]
    }

    static func save(_ meta: ChapterPageMeta) {
        var map = loadAll()
        map[meta.albumKey] = meta
        if let data = try? encoder.encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
        var map = loadAll()
        map.removeValue(forKey: albumKey)
        if let data = try? encoder.encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
