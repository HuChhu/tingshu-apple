import Foundation

/// 通用磁盘缓存信封（对标摸鱼听书的 CacheEnvelope）。
///
/// 为什么需要：模板站改版时数据结构变了，旧缓存会让 UI 显示错乱甚至崩溃。
/// 有了 schema 版本号，改结构就 +1，旧缓存自动失效，不用清全区。
///
/// 与摸鱼的差异：它把 data 存成「JSON 字符串套一层」（为了兼容数组/对象两种形态），
/// Swift 有泛型，这里直接用 T，更干净。
struct CacheEnvelope<T: Codable>: Codable {
    let schema: Int
    let updatedAt: Date
    let data: T
}

/// 按目录存的 JSON 缓存。目录在 Caches/DSHCache/<namespace>/
enum DiskCache {
    private static let rootName = "DSHCache"

    private static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(rootName, isDirectory: true)
    }

    private static func url(namespace: String, key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(safe + ".json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// 写一条缓存（自动建目录）
    static func write<T: Codable>(_ value: T, schema: Int, namespace: String, key: String) {
        let env = CacheEnvelope(schema: schema, updatedAt: Date(), data: value)
        guard let data = try? encoder.encode(env) else { return }
        let file = url(namespace: namespace, key: key)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// 读缓存。schema 不匹配 / 解码失败 / 文件不存在都返回 nil（调用方回源）
    static func read<T: Codable>(_ type: T.Type, schema: Int, namespace: String, key: String) -> T? {
        let file = url(namespace: namespace, key: key)
        guard let data = try? Data(contentsOf: file),
              let env = try? decoder.decode(CacheEnvelope<T>.self, from: data),
              env.schema == schema else { return nil }
        return env.data
    }

    /// 读缓存 + 判断是否过期（供「过期先用旧值、后台刷新」的 stale-while-revalidate 用法）
    static func read<T: Codable>(_ type: T.Type, schema: Int, namespace: String,
                                 key: String, ttl: TimeInterval) -> (value: T, isStale: Bool)? {
        let file = url(namespace: namespace, key: key)
        guard let data = try? Data(contentsOf: file),
              let env = try? decoder.decode(CacheEnvelope<T>.self, from: data),
              env.schema == schema else { return nil }
        let stale = Date().timeIntervalSince(env.updatedAt) > ttl
        return (env.data, stale)
    }

    static func remove(namespace: String, key: String) {
        try? FileManager.default.removeItem(at: url(namespace: namespace, key: key))
    }

    static func clear(namespace: String) {
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(namespace, isDirectory: true))
    }

    static func totalBytes() -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in en {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                sum += Int64(size)
            }
        }
        return sum
    }
}
