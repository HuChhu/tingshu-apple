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
    }

    static func loadFavorites() -> [Favorite] {
        guard let data = UserDefaults.standard.data(forKey: favoriteKey),
              let list = try? decoder.decode([Favorite].self, from: data) else { return [] }
        return list
    }

    @discardableResult
    static func toggleFavorite(bookUrl: String, title: String, author: String,
                               coverUrl: String, albumId: Int64) -> Bool {
        var list = loadFavorites()
        if let i = list.firstIndex(where: { $0.bookUrl == bookUrl }) {
            list.remove(at: i)
            persist(list, favoriteKey)
            return false
        }
        list.insert(Favorite(bookUrl: bookUrl, title: title, author: author,
                             coverUrl: coverUrl, albumId: albumId, addedAt: Date()), at: 0)
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

    private static func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? encoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
