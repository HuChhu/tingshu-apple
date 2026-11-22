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
    }
    static func row(from e: Episode) -> EpisodeRow {
        EpisodeRow(
            title: e.title,
            trackId: e.trackId,
            index: e.index,
            durationMs: e.durationMs,
            coverUrl: e.coverUrl
        )
    }

    // MARK: - 对接点（stub 签名不变；真调用在 Mac 窗口第 2 步换入）
    /// 周1 对接点：search(keywords, page) → SearchResult。stub 返回空书单。
    static func searchStub(keywords: String, page: Int) -> [Book] { [] }

    /// 周2 对接点：extract(url, timeoutMs 默认 15s) → ExtractedAudio(url, headers,
    /// expiresInSeconds)。stub 返回 nil；真调用 = 引擎 extract（类名按 framework 头对拍）。
    /// headers 已由共享核心按 host 精确匹配过滤，壳侧原样注入、不再加工。
    static func extractStub(url: String) -> ExtractedAudio? { nil }

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
}
