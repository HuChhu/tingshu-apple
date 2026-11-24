import Foundation

/// 本地持久化：播放进度 / 书架收藏 / 最近播放。
/// 用 UserDefaults + JSON，不引第三方依赖。
/// 键名带前缀 dsh.tingshu. 便于排查与清理。
/// 跨源唯一标识（修复 UI-04：以前只拿 bookUrl 当主键，不同源的同一本书会串车）。
/// 取值优先级：albumId > 0 用它，否则退回 bookUrl。sourceId 永远参与，保证跨源隔离。
struct BookKey: Hashable, Codable {
    let sourceId: String
    let albumId: Int64
    let bookUrl: String

    init(sourceId: String, albumId: Int64, bookUrl: String) {
        self.sourceId = sourceId
        self.albumId = albumId
        self.bookUrl = bookUrl
    }

    /// 存储用字符串键
    var id: String {
        let body = albumId > 0 ? String(albumId) : bookUrl
        return sourceId + ":" + body
    }
}

enum LocalStore {

    // MARK: - 播放进度

    struct Progress: Codable {
        let bookUrl: String
        /// 用哪个源播的（旧数据缺字段时回落 ximalaya-open）
        var sourceId: String = "ximalaya-open"
        /// 专辑 ID（>0 时与 sourceId 一起构成唯一键）
        var albumId: Int64 = 0

        var bookKey: BookKey { BookKey(sourceId: sourceId, albumId: albumId, bookUrl: bookUrl) }
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

        /// 旧数据没有 sourceId / albumId，必须 decodeIfPresent 才不会整条丢
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookUrl = try c.decode(String.self, forKey: .bookUrl)
            title = try c.decode(String.self, forKey: .title)
            trackId = try c.decode(Int64.self, forKey: .trackId)
            episodeTitle = try c.decode(String.self, forKey: .episodeTitle)
            positionMs = try c.decode(Int64.self, forKey: .positionMs)
            durationMs = try c.decode(Int64.self, forKey: .durationMs)
            updatedAt = try c.decode(Date.self, forKey: .updatedAt)
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? "ximalaya-open"
            albumId = try c.decodeIfPresent(Int64.self, forKey: .albumId) ?? 0
        }

        init(bookUrl: String, title: String, trackId: Int64, episodeTitle: String,
             positionMs: Int64, durationMs: Int64, updatedAt: Date,
             sourceId: String = "ximalaya-open", albumId: Int64 = 0) {
            self.bookUrl = bookUrl; self.title = title; self.trackId = trackId
            self.episodeTitle = episodeTitle; self.positionMs = positionMs
            self.durationMs = durationMs; self.updatedAt = updatedAt
            self.sourceId = sourceId; self.albumId = albumId
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
        // 只写新键。旧键（裸 bookUrl）在读取时做一次迁移，不再双写 ——
        // 双写会导致同一本书换源后出现两条进度、各自覆盖，续播位置错乱。
        all[p.bookKey.id] = p
        if let data = try? encoder.encode(all) {
            UserDefaults.standard.set(data, forKey: progressKey)
        }
    }

    static func loadProgress() -> [String: Progress] {
        guard let data = UserDefaults.standard.data(forKey: progressKey),
              let dict = try? decoder.decode([String: Progress].self, from: data) else { return [:] }
        return dict
    }

    /// 按 BookKey 读（跨源正确）
    static func progress(for key: BookKey) -> Progress? {
        let all = loadProgress()
        if let p = all[key.id] { return p }
        // 旧数据只有 bookUrl 键：读到后迁移到新键并删旧键（只迁一次）
        if let legacy = all[key.bookUrl] {
            var moved = legacy
            moved.sourceId = key.sourceId
            moved.albumId = key.albumId
            var migrated = all
            migrated.removeValue(forKey: key.bookUrl)
            migrated[key.id] = moved
            if let data = try? Self.encoder.encode(migrated) {
                UserDefaults.standard.set(data, forKey: progressKey)
            }
            return moved
        }
        return nil
    }

    static func progress(for bookUrl: String) -> Progress? {
        loadProgress()[bookUrl]
    }

    // MARK: - 收藏

    struct Favorite: Codable, Identifiable {
        /// 兼容旧 id（旧数据没有 sourceId 时等价于 bookUrl）
        var id: String { bookKey.id }
        var bookKey: BookKey { BookKey(sourceId: sourceId, albumId: albumId, bookUrl: bookUrl) }
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
        let probe = BookKey(sourceId: sourceId, albumId: albumId, bookUrl: bookUrl)
        var list = loadFavorites()
        if let i = list.firstIndex(where: { $0.bookKey == probe }) {
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

    /// 按 BookKey 判重（跨源隔离）
    static func isFavorite(sourceId: String, albumId: Int64, bookUrl: String) -> Bool {
        let probe = BookKey(sourceId: sourceId, albumId: albumId, bookUrl: bookUrl)
        return loadFavorites().contains { $0.bookKey == probe }
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
        /// 封面（首页「继续收听」展示用）
        var coverUrl: String = ""

        private enum CodingKeys: String, CodingKey {
            case bookUrl, bookTitle, trackId, episodeTitle, playedAt, sourceId, episodeUrl, coverUrl
        }

        /// 兼容旧数据：缺 sourceId 字段时不崩，回落到喜马拉雅免登录源
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookUrl = try c.decode(String.self, forKey: .bookUrl)
            bookTitle = try c.decode(String.self, forKey: .bookTitle)
            trackId = try c.decode(Int64.self, forKey: .trackId)
            episodeTitle = try c.decode(String.self, forKey: .episodeTitle)
            playedAt = try c.decode(Date.self, forKey: .playedAt)
            sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId) ?? "ximalaya-open"
            episodeUrl = try c.decodeIfPresent(String.self, forKey: .episodeUrl) ?? ""
            coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl) ?? ""
        }
        init(bookUrl: String, bookTitle: String, trackId: Int64, episodeTitle: String, playedAt: Date, sourceId: String, episodeUrl: String = "", coverUrl: String = "") {
            self.coverUrl = coverUrl
            self.bookUrl = bookUrl; self.bookTitle = bookTitle
            self.trackId = trackId; self.episodeTitle = episodeTitle
            self.playedAt = playedAt; self.sourceId = sourceId; self.episodeUrl = episodeUrl
        }

        // 显式编码：字段里有 let 也有 var（coverUrl 有默认值），
        // 手写 init(from:) 之后让编译器再合成 encode(to:) 容易踩对称性问题，
        // 这里两边都写死，键名与上面 decode 调用一一对应。
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bookUrl, forKey: .bookUrl)
            try c.encode(bookTitle, forKey: .bookTitle)
            try c.encode(trackId, forKey: .trackId)
            try c.encode(episodeTitle, forKey: .episodeTitle)
            try c.encode(playedAt, forKey: .playedAt)
            try c.encode(sourceId, forKey: .sourceId)
            try c.encode(episodeUrl, forKey: .episodeUrl)
            try c.encode(coverUrl, forKey: .coverUrl)
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

    /// 从最近记录还原一集（首页「继续收听」点击播放用）
    static func recentEpisode(_ r: Recent) -> SharedBridge.EpisodeRow {
        SharedBridge.episodeRow(title: r.episodeTitle, trackId: r.trackId,
                                index: 0, durationMs: 0,
                                coverUrl: r.coverUrl, url: r.episodeUrl)
    }

    /// 从最近记录还原书卡
    static func recentBook(_ r: Recent) -> SharedBridge.BookCard {
        SharedBridge.BookCard(bookUrl: r.bookUrl, title: r.bookTitle, author: "",
                              coverUrl: r.coverUrl, albumId: SharedBridge.albumId(from: r.bookUrl),
                              trackCount: 0, playCount: 0, isFinished: nil)
    }

    // MARK: - 清理

    static func clearAll() {
        [progressKey, favoriteKey, recentKey].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    // MARK: - 播放偏好（对应安卓设置页第 7/8 项）

    /// 专辑维度的播放配置（对标摸鱼听书每本书独立记住倍速/跳过片头）。
    /// 空白专辑（没设置过）返回 nil，播放器就回落全局默认。
    struct AlbumPlayback: Codable {
        var speed: Double = 1.0
        var skipIntroSec: Int = 0
        var skipOutroSec: Int = 0
        var reverseOrder: Bool = false
        var volumeGainDb: Double = 0
        /// 记录时间，用于排障与「最近改过」排序
        var updatedAt: Date = Date()
    }

    private static let albumPlaybackKey = "albumPlayback.v1"

    static func loadAlbumPlaybacks() -> [String: AlbumPlayback] {
        guard let data = UserDefaults.standard.data(forKey: albumPlaybackKey),
              let map = try? Self.decoder.decode([String: AlbumPlayback].self, from: data) else { return [:] }
        return map
    }

    static func albumPlayback(for key: BookKey) -> AlbumPlayback? {
        loadAlbumPlaybacks()[key.id]
    }

    static func saveAlbumPlayback(_ value: AlbumPlayback, for key: BookKey) {
        var map = loadAlbumPlaybacks()
        var v = value
        v.updatedAt = Date()
        map[key.id] = v
        if let data = try? Self.encoder.encode(map) {
            UserDefaults.standard.set(data, forKey: albumPlaybackKey)
        }
    }

    static func clearAlbumPlayback(for key: BookKey) {
        var map = loadAlbumPlaybacks()
        map.removeValue(forKey: key.id)
        if let data = try? encoder.encode(map) {
            UserDefaults.standard.set(data, forKey: albumPlaybackKey)
        }
    }

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

        // ===== v1.3.0 新增：全局默认值 + 作用域开关（对标摸鱼 is_global_*）=====

        /// 全局默认倍速
        var defaultSpeed: Double = 1.0
        /// true = 所有专辑都用全局倍速，忽略专辑自己的设置
        var useGlobalSpeed: Bool = true
        /// 全局默认跳过片头（秒）
        var defaultSkipIntroSec: Int = 0
        /// 全局默认跳过片尾（秒）
        var defaultSkipOutroSec: Int = 0
        /// true = 跳过片头片尾用全局值
        var useGlobalSkip: Bool = true
        /// true = 音量增益用全局值
        var useGlobalVolume: Bool = true
        /// 全局音量增益（dB，-12 ~ +12）
        var volumeGainDb: Double = 0

        // ===== 睡眠定时 =====

        /// 重启 App 后按上次设置重新定时
        var sleepAutoEnable: Bool = false
        /// 上次「按时间」的分钟数
        var sleepLastMinutes: Int = 30
        /// 上次「按章节」的章节数
        var sleepLastChapters: Int = 3

        /// 旧数据没有这些新键，必须手写 decode 兜底
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seekSeconds = try c.decodeIfPresent(Int.self, forKey: .seekSeconds) ?? 10
            resumeRewindSeconds = try c.decodeIfPresent(Int.self, forKey: .resumeRewindSeconds) ?? 0
            autoPlayOnOpen = try c.decodeIfPresent(Bool.self, forKey: .autoPlayOnOpen) ?? false
            skipSilence = try c.decodeIfPresent(Bool.self, forKey: .skipSilence) ?? false
            ignoreAudioFocus = try c.decodeIfPresent(Bool.self, forKey: .ignoreAudioFocus) ?? false
            defaultSpeed = try c.decodeIfPresent(Double.self, forKey: .defaultSpeed) ?? 1.0
            useGlobalSpeed = try c.decodeIfPresent(Bool.self, forKey: .useGlobalSpeed) ?? true
            defaultSkipIntroSec = try c.decodeIfPresent(Int.self, forKey: .defaultSkipIntroSec) ?? 0
            defaultSkipOutroSec = try c.decodeIfPresent(Int.self, forKey: .defaultSkipOutroSec) ?? 0
            useGlobalSkip = try c.decodeIfPresent(Bool.self, forKey: .useGlobalSkip) ?? true
            useGlobalVolume = try c.decodeIfPresent(Bool.self, forKey: .useGlobalVolume) ?? true
            volumeGainDb = try c.decodeIfPresent(Double.self, forKey: .volumeGainDb) ?? 0
            sleepAutoEnable = try c.decodeIfPresent(Bool.self, forKey: .sleepAutoEnable) ?? false
            sleepLastMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepLastMinutes) ?? 30
            sleepLastChapters = try c.decodeIfPresent(Int.self, forKey: .sleepLastChapters) ?? 3
        }

        init() {}
    }

    /// 解析某本书最终生效的播放参数（专辑值 > 全局默认）
    static func effective(for key: BookKey, prefs: PlayPrefs) -> AlbumPlayback {
        let album = albumPlayback(for: key)
        var out = AlbumPlayback()
        // 夹紧到合法区间：AVPlayer 收到 rate <= 0 或 NaN 会出问题，这是搜索书闪退的高危点
        let rawSpeed = prefs.useGlobalSpeed ? prefs.defaultSpeed : (album?.speed ?? prefs.defaultSpeed)
        out.speed = rawSpeed.isFinite ? min(3.0, max(0.5, rawSpeed)) : 1.0
        out.skipIntroSec = max(0, prefs.useGlobalSkip ? prefs.defaultSkipIntroSec : (album?.skipIntroSec ?? 0))
        out.skipOutroSec = max(0, prefs.useGlobalSkip ? prefs.defaultSkipOutroSec : (album?.skipOutroSec ?? 0))
        let rawGain = prefs.useGlobalVolume ? prefs.volumeGainDb : (album?.volumeGainDb ?? 0)
        out.volumeGainDb = rawGain.isFinite ? min(12, max(-12, rawGain)) : 0
        out.reverseOrder = album?.reverseOrder ?? false
        return out
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
