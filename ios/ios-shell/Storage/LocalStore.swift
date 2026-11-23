import Foundation

/// 本地持久化：播放进度 / 书架收藏 / 最近播放。
/// 用 UserDefaults + JSON，不引第三方依赖。
/// 键名带前缀 dsh.tingshu. 便于排查与清理。
enum LocalStore {

    // MARK: - 播放进度

    struct Progress: Codable {
        let bookUrl: String
        let title: String
        let trackId: Int64
        let episodeTitle: String
        let positionMs: Int64
        let durationMs: Int64
        let updatedAt: Date

        var fraction: Double {
            guard durationMs > 0 else { return 0 }
            return min(1.0, Double(positionMs) / Double(durationMs))
        }
    }

    private static let progressKey = "dsh.tingshu.progress"
    private static let favoriteKey = "dsh.tingshu.favorites"
    private static let recentKey = "dsh.tingshu.recent"
    private static let maxRecent = 20

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // MARK: - 进度（按 bookUrl 存，一本一条）

    static func saveProgress(_ p: Progress) {
        var all = loadProgress()
        all[p.bookUrl] = p
        if let data = try? encoder.encode(all) {
            UserDefaults.standard.set(data, forKey: progressKey)
        }
    }

    static func loadProgress() -> [String: Progress] {
        guard let data = UserDefaults.standard.data(forKey: progressKey),
              let dict = try? decoder.decode([String: Progress].self, from: data) else { return [:] }
        return dict
    }

    static func progress(for bookUrl: String) -> Progress? {
        loadProgress()[bookUrl]
    }

    // MARK: - 收藏

    struct Favorite: Codable, Identifiable {
        var id: String { bookUrl }
        let bookUrl: String
        let title: String
        let author: String
        let coverUrl: String
        let albumId: Int64
        let addedAt: Date
        /// 收藏时用的源（多源支持；旧数据缺字段时回落 ximalaya-open）
        let sourceId: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookUrl = try c.decode(String.self, forKey: .bookUrl)
            title = try c.decode(String.self, forKey: .title)
            author = try c.decode(String.self, forKey: .author)
            coverUrl = try c.decode(String.self, forKey: .coverUrl)
            albumId = try c.decode(Int64.self, forKey: .albumId)
            addedAt = try c.decode(Date.self, forKey: .addedAt)
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? "ximalaya-open"
            episodeUrl = try c.decodeIfPresent(String.self, forKey: .episodeUrl) ?? ""
        }
        init(bookUrl: String, title: String, author: String, coverUrl: String, albumId: Int64, addedAt: Date, sourceId: String) {
            self.bookUrl = bookUrl; self.title = title; self.author = author
            self.coverUrl = coverUrl; self.albumId = albumId
            self.addedAt = addedAt; self.sourceId = sourceId
        }
    }

    static func loadFavorites() -> [Favorite] {
        guard let data = UserDefaults.standard.data(forKey: favoriteKey),
              let list = try? decoder.decode([Favorite].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func toggleFavorite(
        bookUrl: String, title: String, author: String,
        coverUrl: String, albumId: Int64,
        sourceId: String = "ximalaya"
    ) -> Bool {
        var list = loadFavorites()
        if let i = list.firstIndex(where: { $0.bookUrl == bookUrl }) {
            list.remove(at: i)
            persist(list, favoriteKey)
            return false
        }
        list.insert(Favorite(
            bookUrl: bookUrl, title: title, author: author,
            coverUrl: coverUrl, albumId: albumId,
            addedAt: Date(), sourceId: sourceId), at: 0)
        persist(list, favoriteKey)
        return true
    }

    static func isFavorite(_ bookUrl: String) -> Bool {
        loadFavorites().contains { $0.bookUrl == bookUrl }
    }

    // MARK: - 最近播放

    struct Recent: Codable, Identifiable {
        var id: String { bookUrl + "#" + String(trackId) }
        let bookUrl: String
        let bookTitle: String
        let trackId: Int64
        let episodeTitle: String
        let playedAt: Date
        /// 用哪个源播的（多源支持；旧记录没有此字段时默认 ximalaya-open）
        let sourceId: String
        /// 该集的原始页面/音频地址（P1-07：模板集的 trackId 是数字，不能当 URL 用）
        let episodeUrl: String

        /// 兼容旧数据：缺 sourceId 字段时不崩，回落到喜马拉雅免登录源
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookUrl = try c.decode(String.self, forKey: .bookUrl)
            bookTitle = try c.decode(String.self, forKey: .bookTitle)
            trackId = try c.decode(Int64.self, forKey: .trackId)
            episodeTitle = try c.decode(String.self, forKey: .episodeTitle)
            playedAt = try c.decode(Date.self, forKey: .playedAt)
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? "ximalaya-open"
        }
        init(bookUrl: String, bookTitle: String, trackId: Int64, episodeTitle: String, playedAt: Date, sourceId: String, episodeUrl: String = "") {
            self.bookUrl = bookUrl; self.bookTitle = bookTitle
            self.trackId = trackId; self.episodeTitle = episodeTitle
            self.playedAt = playedAt; self.sourceId = sourceId; self.episodeUrl = episodeUrl
        }
    }

    static func pushRecent(_ r: Recent) {
        var list = loadRecent().filter { $0.id != r.id }
        list.insert(r, at: 0)
        if list.count > maxRecent { list = Array(list.prefix(maxRecent)) }
        persist(list, recentKey)
    }

    static func loadRecent() -> [Recent] {
        guard let data = UserDefaults.standard.data(forKey: recentKey),
              let list = try? decoder.decode([Recent].self, from: data) else { return [] }
        return list
    }

    static func clearRecent() { UserDefaults.standard.removeObject(forKey: recentKey) }

    // MARK: - 清理

    static func clearAll() {
        [progressKey, favoriteKey, recentKey].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    // MARK: - 播放偏好（对应安卓设置页第 7/8 项）

    struct PlayPrefs: Codable {
        /// 快进快退秒数（安卓默认 10，重启生效）
        var seekSeconds: Int = 10
        /// 恢复播放时后退几秒，0=关闭（安卓默认 0）
        var resumeRewindSeconds: Int = 0
        /// 进入播放页自动播放（安卓默认关）
        var autoPlayOnOpen: Bool = false
        /// 跳过无声部分（安卓默认关）
        var skipSilence: Bool = false
        /// 忽略其它 App 音频焦点（普通模式：接电话仍暂停）
        var ignoreAudioFocus: Bool = false
    }

    private static let playPrefsKey = "dsh.tingshu.playPrefs"

    static func loadPlayPrefs() -> PlayPrefs {
        guard let data = UserDefaults.standard.data(forKey: playPrefsKey),
              let p = try? decoder.decode(PlayPrefs.self, from: data) else {
            return PlayPrefs()
        }
        return p
    }

    static func savePlayPrefs(_ p: PlayPrefs) {
        if let data = try? encoder.encode(p) {
            UserDefaults.standard.set(data, forKey: playPrefsKey)
        }
    }

    private static func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? encoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
