// clean-room 契约转录（来源：docs/苹果化-引擎接口契约v1.md，lead 原创设计）
// 字段扩展（dev-core）：M1 追加 Book/SearchResult 尾部默认值字段（对齐 bridge normalize_album）；
// M2 追加 Episode.coverUrl（对齐 bridge normalize_track cover 字段）与 CookieProvider SPI（lead 拍板）。
// 既有字段名与位置不变，契约签名不变。
package com.local.audiobook.core

interface SourceActions {
    val sourceId: String
    val url: String
    val name: String
    val desc: String
    val capabilities: Capabilities

    suspend fun search(keywords: String, page: Int): SearchResult
    suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail
    fun audioExtractor(): AudioExtractor

    /**
     * 登录入口。null = 这个源不需要登录。
     * 对应 TingShu.getLoginUrl / isLoginDesktop。
     */
    fun loginEntry(): LoginEntry? = null

    /**
     * 搜索验证入口。null = 该源搜索不会被风控拦。
     * 对应 TingShu.getSearchVerificationUrl / getSearchVerificationUA。
     */
    fun searchVerification(): SearchVerification? = null

    /**
     * 源的可配置项。空 = 无可配置。
     * 对应 TingShu.getCustomConfigItems。
     */
    fun configItems(): List<ConfigItem> = emptyList()

    /**
     * 当前源的音频地址能否缓存。
     * 对应 TingShu.isCacheable。地址有时效的源应返回 false。
     */
    fun cacheableAudio(): Boolean = capabilities.cacheable
}

data class Capabilities(
    val searchable: Boolean,
    val discoverable: Boolean,
    val cacheable: Boolean,
    val needsWebView: Boolean,
    /** 搜索被风控拦住时，能否通过人工验证恢复（对应 TingShu.isSearchValidated） */
    val searchVerifiable: Boolean = false,
    /** 是否需要登录才能用（对应 TingShu.getLoginUrl 非空） */
    val needsLogin: Boolean = false,
    /** 章节是否分页加载（对应 TingShu.isMultipleEpisodePages） */
    val multipleEpisodePages: Boolean = false,
)

/**
 * 源的登录入口（对应 TingShu.getLoginUrl / isLoginDesktop）。
 * 为空表示这个源不需要登录。
 */
data class LoginEntry(
    val url: String,
    /** true = 用桌面 UA 加载登录页 */
    val desktop: Boolean = false,
)

/**
 * 搜索验证入口（对应 TingShu.getSearchVerificationUrl / getSearchVerificationUA）。
 * 被风控拦住时，平台层用这个地址拉起 WebView 让用户人工过验证。
 */
data class SearchVerification(
    val url: String,
    val userAgent: String = "",
    /** 两次搜索之间的建议延迟，防硬冲（对应 TingShu.getSearchDelayMs） */
    val delayMs: Long = 0L,
)

/**
 * 源的可配置项（对应 TingShu.getCustomConfigItems）。
 * 让用户能给不同源配不同参数，比如 UA、Cookie、镜像地址。
 */
data class ConfigItem(
    val key: String,
    val label: String,
    val defaultValue: String = "",
    val hint: String = "",
)
data class SearchResult(val books: List<Book>, val maxPage: Int, val source: String = "", val page: Int = 1, val hint: String? = null)
data class Book(
    val sourceId: String, val bookUrl: String, val title: String, val author: String, val coverUrl: String, val intro: String,
    val albumId: Long = 0L, val trackCount: Long = 0L, val playCount: Long = 0L, val isFinished: Boolean? = null,
)
data class BookDetail(val book: Book, val episodes: List<Episode>)
/**
 * 一集。url 的语义是「音频直链」；取不到直链时**留空**，绝不填网页地址。
 *
 * 2026-11-25 修「搜出来的书播不了」：以前 playUrl 为空时拿 DetailRoutes.soundUrl 顶上，
 * 于是 https://www.ximalaya.com/sound/{id} 这个**网页**一路流到 AVPlayer，
 * 被出口闸拦下后报「只给了网页地址」，用户看到的是「播不了」但不知道为什么。
 * 现在：url 空 = 本集没有直链（典型就是喜马 VIP/付费轨，mobwsa 返回 playUrl64="" ），
 * 由 playable=false + hint 说明原因，UI 直接展示，不再走「取地址失败」那条含糊的错路。
 */
data class Episode(
    val title: String,
    val url: String,
    val trackId: Long = 0L,
    val index: Int = 0,
    val durationMs: Long = 0L,
    val coverUrl: String = "",
    /** 本集能否直接播（有直链）。false 时 hint 一定非空。 */
    val playable: Boolean = true,
    /** 不能播的原因，UI 原样展示（例：本集为付费内容 0.20 喜点/集，登录并开通会员后可听）。 */
    val hint: String = "",
)

interface AudioExtractor {
    suspend fun extract(url: String, timeoutMs: Int = 15_000): ExtractedAudio
}
data class ExtractedAudio(val url: String, val headers: Map<String, String>, val expiresInSeconds: Long = 0L)

// CookieProvider SPI（lead 拍板 2026-11-21）：登录态按平台注入；null=匿名。
// JVM spike=桥持会话（env 路径读凭据，值不进 git/日志）；iOS M4=WKWebView 官方页登录后拷 HTTPCookieStorage。
/**
 * 会员等级（v1.4.4，用户反馈：登录了一个没有会员的账号，界面却写「可听会员内容」）。
 *
 * 一切未知/未登录/取不到 ── 一律归 Unknown，**不许默认当会员**。
 */
enum class VipTier {
    /** 未登录（没有 Cookie） */
    NotLoggedIn,
    /** 已登录，但会员状态拿不到（接口失败/字段缺失） */
    Unknown,
    /** 已登录，确定没有会员 */
    None,
    /** 普通会员 */
    Normal,
    /** 白金会员 */
    Platinum,
    /** 大师会员 */
    Master,
    /** 儿童会员 */
    Kids,
}

/**
 * 会员状态结果。
 *
 * @param tier        等级（永远非空，取不到就是 Unknown）
 * @param expireDate  有效期 yyyy-MM-dd（拿不到就是空串，UI 不显示这一行）
 * @param nickname    昵称（可空）
 * @param rawVipLevel 上游原始等级数值（-1 = 未知），仅排障用
 * @param source      数据来源："api" | "webview" | "cookie" | "none"
 */
data class VipStatus(
    val tier: VipTier,
    val expireDate: String = "",
    val nickname: String = "",
    val rawVipLevel: Int = -1,
    val source: String = "none",
)

interface CookieProvider {
    suspend fun cookie(): String?
    suspend fun refresh()
}

// 契约v1转录差异②（M2 机械需要）：sealed interface → sealed class（继承 RuntimeException）。
// 原因：Kotlin throw 要求表达式静态类型为 Throwable 子类型；「接口成员各自实现 RuntimeException」
// 无法让以接口静态类型 throw 的表达式过编译，而引擎的错误传播全部走 throw。
// 结构/成员名/字段与契约 v1 一致。差异①Network.cause→reason ②interface→class 均已报 lead 记入契约 v1.1。
sealed class SourceErrors : RuntimeException() {
    data class NotFound(val url: String) : SourceErrors()
    data class ParseFailed(val reason: String) : SourceErrors()
    data class RateLimited(val needVerification: Boolean) : SourceErrors()
    data class Network(val reason: String) : SourceErrors()
    data class Auth(val reason: String) : SourceErrors()
    /** 需要付费会员（与「未登录」区分开，提示文案不同） */
    data class Vip(val reason: String) : SourceErrors()
    data class Upstream(val status: Int) : SourceErrors()
}

interface PlaybackStateSink { fun onState(state: PlaybackState) }
enum class PlaybackState { PLAYING, PAUSED, ERROR, STOPPED }
