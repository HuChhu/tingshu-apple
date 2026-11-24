import Foundation
import UIKit

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
            // 崩溃路径绝对不能抢 NSLock：如果主线程正持锁写日志，这里会死锁，
            // 最需要的那条崩溃栈反而丢失。用独立文件 + 无锁直写。
            let name = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let text = "=== FATAL ===\n\(name): \(reason)\n\(stack)\n"
            let f = dir.appendingPathComponent("fatal-\(Int(Date().timeIntervalSince1970)).log")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.data(using: .utf8)?.write(to: f)
        }
    }

    /// 高频标签（每秒都会打）不做 fsync，否则主线程被拖慢
    private static let highFrequencyTags: Set<String> = ["TICK", "PROGRESS", "UI"]

    /// 写一条日志。线程安全，写失败静默（日志不能拖垮主流程）。
    /// 日期格式器只建一次（每次 new DateFormatter 在主线程上是毫秒级开销）
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 复用文件句柄：每次 open/close 比写好几百字节本身贵得多
    private static var handle: FileHandle?
    private static var handlePath: String?

    static func write(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(df.string(from: Date()))][\(tag)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = currentFile

        // 跨天换文件：路径变了就重开句柄
        if handle == nil || handlePath != file.path {
            try? handle?.close()
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: file)
            handlePath = file.path
            try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        try? h.write(contentsOf: data)

        // 只对「关键事件」fsync：崩溃后要保住的那几条。高频标签不同步，避免拖慢主线程。
        if !highFrequencyTags.contains(tag) {
            try? h.synchronize()
        }
    }

    /// 进程退出前调用一次，把缓冲刷盘
    static func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
    }

    /// 装「进后台 / 将终止」钩子：非关键事件的日志这时统一刷盘，
    /// 平时不做 fsync 省主线程开销，真正退出前一条都不丢。
    static func installFlushObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: nil) { _ in flush() }
        nc.addObserver(forName: UIApplication.willTerminateNotification,
                       object: nil, queue: nil) { _ in flush() }
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
        lock.lock()
        defer { lock.unlock() }
        // 必须先关句柄再删文件：否则后续写入会进已 unlink 的 fd，静默丢日志
        try? handle?.close()
        handle = nil
        handlePath = nil
        for f in allFiles() { try? FileManager.default.removeItem(at: f) }
    }

    static var totalBytes: Int64 {
        allFiles().reduce(0) { sum, f in
            sum + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
