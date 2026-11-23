import Foundation

/// 崩溃与错误记录（写在 Documents/crash/ 下，用户能直接导出）。
/// 参考摸鱼听书的 RepoLog / SourceLog：它把关键路径都打日志，出问题能定位。
/// iOS 有个限制：App 自己闪退时进程被杀，来不及写日志，所以这里分两类：
///   ① 可捕获的错误（Kotlin 异常、网络失败、解码失败）—— 立即落盘
///   ② 未捕获异常（NSException）—— 用 NSSetUncaughtExceptionHandler 抢在进程结束前写
enum CrashLog {
    private static let dirName = "crash"
    private static let lock = NSLock()

    static var dir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(dirName, isDirectory: true)
    }

    static var currentFile: URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return dir.appendingPathComponent("app-\(df.string(from: Date())).log")
    }

    /// 安装未捕获异常处理器。放在 App 启动最早处（AppDelegate/init 里）。
    static func installUncaughtHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            CrashLog.write("FATAL", "\(name): \(reason)\n\(stack)")
        }
    }

    /// 写一条日志。线程安全，写失败静默（日志不能拖垮主流程）。
    static func write(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "[\(df.string(from: Date()))][\(tag)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = currentFile
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// 便捷：记录一次播放失败（带上下文，出问题时一眼看出是哪本书哪一集）
    static func playbackFailed(book: String, episode: String, trackId: Int64,
                               source: String, reason: String) {
        write("PLAY", "book=\(book) ep=\(episode) track=\(trackId) src=\(source) -> \(reason)")
    }

    /// 便捷：记录搜索（慢的时候能看出慢在哪一路）
    static func search(_ keyword: String, path: String, ms: Int, count: Int, note: String = "") {
        write("SEARCH", "kw=\(keyword) path=\(path) took=\(ms)ms count=\(count) \(note)")
    }

    /// 列出所有日志文件（设置页「导出日志」用）
    static func allFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            } ?? []
    }

    /// 合并全部日志成一份文本（给用户复制/分享）
    static func merged() -> String {
        allFiles().compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    static func clear() {
        for f in allFiles() { try? FileManager.default.removeItem(at: f) }
    }

    static var totalBytes: Int64 {
        allFiles().reduce(0) { sum, f in
            sum + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
