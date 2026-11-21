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
}

data class Capabilities(val searchable: Boolean, val discoverable: Boolean, val cacheable: Boolean, val needsWebView: Boolean)
data class SearchResult(val books: List<Book>, val maxPage: Int, val source: String = "", val page: Int = 1, val hint: String? = null)
data class Book(
    val sourceId: String, val bookUrl: String, val title: String, val author: String, val coverUrl: String, val intro: String,
    val albumId: Long = 0L, val trackCount: Long = 0L, val playCount: Long = 0L, val isFinished: Boolean? = null,
)
data class BookDetail(val book: Book, val episodes: List<Episode>)
data class Episode(val title: String, val url: String, val trackId: Long = 0L, val index: Int = 0, val durationMs: Long = 0L, val coverUrl: String = "")

interface AudioExtractor {
    suspend fun extract(url: String, timeoutMs: Int = 15_000): ExtractedAudio
}
data class ExtractedAudio(val url: String, val headers: Map<String, String>, val expiresInSeconds: Long = 0L)

// CookieProvider SPI（lead 拍板 2026-11-21）：登录态按平台注入；null=匿名。
// JVM spike=桥持会话（env 路径读凭据，值不进 git/日志）；iOS M4=WKWebView 官方页登录后拷 HTTPCookieStorage。
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
    data class Upstream(val status: Int) : SourceErrors()
}

interface PlaybackStateSink { fun onState(state: PlaybackState) }
enum class PlaybackState { PLAYING, PAUSED, ERROR, STOPPED }
