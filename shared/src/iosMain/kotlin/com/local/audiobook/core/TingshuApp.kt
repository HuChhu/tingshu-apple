package com.local.audiobook.core

import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.core.net.IosJsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin

/**
 * Swift 侧唯一入口（framework 导出的门面）。
 *
 * 装配纪律与 jvmMain/Main.kt 一致：
 *  - 限速 1 请求/秒、并发 1
 *  - 网页搜索预算 3 次 / 30s 冷却
 *  - 时钟走 PlatformClock（commonMain 无 System）
 *
 * 错误传播：引擎 throw SourceErrors 子类；本类把异常转成 XimalayaResult，
 * 避免 Swift 侧接 Kotlin 异常（K/N 异常桥接在 Swift 里是 NSError，语义易丢）。
 */
class TingshuApp(
    cookieProvider: CookieProvider = object : CookieProvider {
        override suspend fun cookie(): String? = null
        override suspend fun refresh() {}
    },
) {
    private val client: HttpClient = HttpClient(Darwin)

    private val engine: SearchEngine = SearchEngine(
        fetcher = IosJsonFetcher(client),
        throttle = RequestThrottle(minIntervalMs = 1_000L, clock = { PlatformClock.nowMs() }),
        budget = WebSearchBudget(now = { PlatformClock.nowMs() }),
        nowMs = { PlatformClock.nowMs() },
        cookieProvider = cookieProvider,
    )

    /** 搜索。返回 SearchResult；失败时 books 空 + source="error" + hint 带原因。 */
    suspend fun search(keywords: String, page: Int): SearchResult = try {
        engine.search(keywords, page)
    } catch (e: SourceErrors) {
        SearchResult(books = emptyList(), maxPage = 0, source = "error", page = page, hint = describe(e))
    }

    /** 专辑详情 + 曲目。失败抛 SourceErrors（Swift 侧按 NSError 接）。 */
    suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean = true, loadFullPages: Boolean = false): BookDetail =
        engine.bookDetail(bookUrl, loadEpisodes, loadFullPages)

    /** 取播放地址（级1→级3 提取链）。失败抛 SourceErrors。 */
    suspend fun extract(url: String, timeoutMs: Int = 15_000): ExtractedAudio =
        engine.audioExtractor().extract(url, timeoutMs)

    /** 解析专辑 ID（/album/{id}、?albumId=、纯数字 ≥4 位）。 */
    fun parseAlbumId(bookUrl: String): Long = engine.parseAlbumId(bookUrl) ?: 0L

    fun close() { client.close() }

    private fun describe(e: SourceErrors): String = when (e) {
        is SourceErrors.NotFound -> "没有找到该资源"
        is SourceErrors.ParseFailed -> "解析失败：" + e.reason
        is SourceErrors.RateLimited -> "触发限流，稍后再试，不硬冲"
        is SourceErrors.Network -> "网络异常：" + e.reason
        is SourceErrors.Auth -> "登录态失效，请重新登录"
        is SourceErrors.Upstream -> "上游服务异常（HTTP " + e.status + "）"
    }
}
