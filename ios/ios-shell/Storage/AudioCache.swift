import Foundation

/// 音频缓存管理器。
///
/// 功能对照「我的听书」的设置页截图：
///   ① 自动缓存后续章节（开关）
///   ② 每本书最大缓存集数（默认 3）
///   ③ 缓存频率（快/标准/省电）
///   ④ 只在 WiFi 条件下缓存
///   ⑤ 自动清理：超过指定数量按最老的时间清理
///   ⑥ 清除所有音频缓存
///
/// 设计要点：
///   - 缓存文件按 bookUrl 哈希分目录，避免文件名冲突
///   - 用 LRU（最近最少使用）清理，读一次就更新 mtime
///   - 只在 WiFi 判断走 NWPathMonitor，但壳侧白名单不允许额外 import，
///     所以这里只提供「策略」和「开关」，实际网络类型由调用方判断
enum AudioCache {

    // MARK: - 设置项（UserDefaults 持久化）

    struct Settings: Codable {
        /// 自动缓存后续章节
        var autoCacheNext: Bool = true
        /// 每本书最大缓存集数
        var maxEpisodesPerBook: Int = 3
        /// 缓存频率：0=省电 1=标准 2=激进
        var frequency: Int = 1
        /// 只在 WiFi 下缓存
        var wifiOnly: Bool = false
        /// 缓存总上限（MB），超过按最老清理
        var maxTotalMB: Int = 500
    }

    private static let settingsKey = "dsh.tingshu.audioCache.settings"

    static func loadSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return s
    }

    static func saveSettings(_ s: Settings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: - 目录

    /// 缓存根目录：Caches/audio/
    static var rootDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("audio", isDirectory: true)
    }

    /// 某本书的缓存目录（用 bookUrl 的稳定哈希做名）
    static func dir(for bookUrl: String) -> URL {
        rootDir.appendingPathComponent(stableName(bookUrl), isDirectory: true)
    }

    /// 某集的缓存文件路径
    static func file(bookUrl: String, trackId: Int64, ext: String = "m4a") -> URL {
        dir(for: bookUrl).appendingPathComponent("\(trackId).\(ext)")
    }

    /// bookUrl → 稳定短名（FNV-1a，避免用 Swift hashValue 因为每次启动会变）
    static func stableName(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    // MARK: - 读写

    /// 已缓存就直接返回本地路径
    static func cachedFile(bookUrl: String, trackId: Int64) -> URL? {
        let f = file(bookUrl: bookUrl, trackId: trackId)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        // 读一次就更新 mtime，实现 LRU
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return f
    }

    /// 这个缓存文件是不是真的音频。
    ///
    /// 【P0 v1.4.8】真机日志：trackId 命中缓存 → 走 local → status 永远 0 →「轮盘一直转但没声音」。
    /// 原因是缓存里存的是**错误页 HTML**：模板站对不带 Referer 的请求回 200 + text/html，
    /// 旧代码只判 `size > 16KB`，9780079 字节的 HTML 轻松过关；而且 cachedFile 每次命中都刷新 mtime，
    /// LRU 永远清不掉它，于是每次都播同一个坏文件。
    ///
    /// 判据：读前 12 字节，认音频容器的魔数。认不出就不当缓存用（调用方负责删掉它重下）。
    /// 命中缓存后做一次内容校验：不是音频就删掉返回 nil，让调用方走网络重新下载。
    static func playableCachedFile(bookUrl: String, trackId: Int64) -> URL? {
        guard let f = cachedFile(bookUrl: bookUrl, trackId: trackId) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber
        if (size?.int64Value ?? 0) < 16 * 1024 || !looksLikeAudio(f) {
            // 坏文件必须删：不删的话下次还会命中，用户永远播不了这一集
            try? FileManager.default.removeItem(at: f)
            return nil
        }
        return f
    }

    static func looksLikeAudio(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        // read(upToCount:) 抛错返回 Data?，try? 在 Swift 5 会扁平化 —— 这里已经是 Data?
        guard let d = try? fh.read(upToCount: 12), d.count >= 4 else { return false }
        let b = [UInt8](d)
        // ID3v2（mp3 带标签）
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return true }
        // MPEG 帧同步：FF Ex / FF Fx
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return true }
        // ftyp（mp4/m4a/m4s）：第 4~7 字节是 "ftyp"
        if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true }
        // OggS / fLaC / RIFF(WAV)
        if b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 { return true }
        if b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return true }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return true }
        return false
    }

    /// 确保目录存在
    @discardableResult
    static func ensureDir(bookUrl: String) -> Bool {
        let d = dir(for: bookUrl)
        if FileManager.default.fileExists(atPath: d.path) { return true }
        return (try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)) != nil
    }

    // MARK: - 统计与清理

    /// 总缓存大小（字节）
    static func totalBytes() -> Int64 {
        guard let en = FileManager.default.enumerator(at: rootDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in en {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    /// 人类可读大小
    static func humanSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// 清理某本书超过上限的集数（保留最新的 N 集）
    static func trimBook(bookUrl: String, keep: Int) {
        let d = dir(for: bookUrl)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b   // 新的在前
        }
        for old in sorted.dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// 全局自动清理：超过 maxTotalMB 就按最老的时间删
    static func autoTrimIfNeeded(settings: Settings) {
        let limit = Int64(settings.maxTotalMB) * 1024 * 1024
        guard totalBytes() > limit else { return }
        guard let en = FileManager.default.enumerator(
            at: rootDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }

        var files: [(URL, Date, Int64)] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = v?.contentModificationDate ?? .distantPast
            let size = Int64(v?.fileSize ?? 0)
            files.append((url, date, size))
        }
        files.sort { $0.1 < $1.1 }   // 最老的在前

        var current = files.reduce(Int64(0)) { acc, item in acc + item.2 }
        for (url, _, size) in files {
            if current <= limit { break }
            try? FileManager.default.removeItem(at: url)
            current -= size
        }
    }

    /// 清除所有音频缓存
    static func clearAll() {
        guard FileManager.default.fileExists(atPath: rootDir.path) else { return }
        try? FileManager.default.removeItem(at: rootDir)
    }

    // MARK: - 按专辑统计（「缓存管理」页）

    /// 磁盘上一个专辑缓存目录的统计结果
    struct DirStat {
        let dirName: String      // stableName(bookUrl)
        let bytes: Int64
        let fileCount: Int
        let oldest: Date         // 最旧文件的修改时间（给界面显示「缓存于 …」）
    }

    /// 列出所有专辑缓存目录（不解析书名，纯文件系统事实）。
    /// 以前只有 totalBytes() 一个总数，用户不知道缓存了哪些书、也没法单删。
    static func listDirs() -> [DirStat] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootDir.path) else { return [] }
        var out: [DirStat] = []
        for name in names {
            let d = rootDir.appendingPathComponent(name, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            var bytes: Int64 = 0
            var oldest = Date()
            var counted = 0
            for f in files {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let v = v else { continue }
                bytes += Int64(v.fileSize ?? 0)
                counted += 1
                if let d = v.contentModificationDate, d < oldest { oldest = d }
            }
            if counted > 0 { out.append(DirStat(dirName: name, bytes: bytes, fileCount: counted, oldest: oldest)) }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// 删掉一个专辑的缓存（按 stableName 删目录）
    static func removeDir(named dirName: String) {
        guard !dirName.isEmpty else { return }
        try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(dirName, isDirectory: true))
    }
}
