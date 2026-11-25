package com.local.audiobook.core

import com.local.audiobook.core.engine.KuwoSource
import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.core.engine.VipStatusResolver
import com.local.audiobook.core.engine.XimalayaOpenSource
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.core.SourceRegistry.AudioResult
import com.local.audiobook.core.SourceRegistry.BookDetailResult
import com.local.audiobook.core.net.IosJsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
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
    /** 会员状态查询用的同一份 Cookie（与引擎共享） */
    private val cookies: CookieProvider = cookieProvider

    private val client: HttpClient = HttpClient(Darwin) {
        install(HttpTimeout) {
            // 45s 不是拍的：aisongli / eshengda / ting954 三个模板站首页实测要 40-45 秒才返回 200，
            // 原来是 32s —— 那几个站在真机上永远 0 本，用户看到的是「这个源没书」。
            // 代价是真正失败的请求要多等 13 秒；换来的是慢站能用。搜索本身另有 9s 硬上限，
            // 所以这里放宽不会拖慢搜索（搜索超时在 SharedBridge.searchTimeoutSeconds）。
            requestTimeoutMillis = 45_000
            connectTimeoutMillis = 12_000
            socketTimeoutMillis = 45_000
        }
    }

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
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: SourceErrors) {
        SearchResult(books = emptyList(), maxPage = 0, source = "error", page = page, hint = describe(e))
    } catch (e: Throwable) {
        SearchResult(books = emptyList(), maxPage = 0, source = "error", page = page,
            hint = "搜索异常：" + (e.message ?: e::class.simpleName ?: "未知"))
    }

    /**
     * 专辑详情 + 曲目。
     * 【P0 修复 2026-11-24】原来这里直接 throw SourceErrors 给 Swift。
     * 但 K/N 头文件明确「Other uncaught Kotlin exceptions are fatal」——
     * 只要抛出的是非 SourceErrors（比如 NPE、IllegalState、解析异常），
     * Swift 侧接不到，进程直接 abort，表现为"点播放闪退"。
     * 现在统一返回 BookDetailResult：detail 为 null 时 reason 一定非空。
     */
    suspend fun bookDetailSafe(bookUrl: String, loadEpisodes: Boolean = true, loadFullPages: Boolean = false): BookDetailResult =
        try {
            BookDetailResult(detail = engine.bookDetail(bookUrl, loadEpisodes, loadFullPages), reason = null)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SourceErrors) {
            BookDetailResult(detail = null, reason = describe(e))
        } catch (e: Throwable) {
            BookDetailResult(detail = null, reason = "详情解析失败：" + (e.message ?: e::class.simpleName ?: "未知"))
        }

    /**
     * 取播放地址。
     * 同样改成不抛：失败返回 AudioResult(audio = null, reason = ...)。
     */
    suspend fun extractSafe(url: String, timeoutMs: Int = 15_000): AudioResult =
        try {
            AudioResult(audio = engine.audioExtractor().extract(url, timeoutMs), reason = null)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SourceErrors) {
            AudioResult(audio = null, reason = describe(e))
        } catch (e: Throwable) {
            AudioResult(audio = null, reason = "解析地址失败：" + (e.message ?: e::class.simpleName ?: "未知"))
        }

    // ---------- 免登录源（不需要登录，直接可用） ----------

    private val xmOpen: XimalayaOpenSource = XimalayaOpenSource(
        fetcher = IosJsonFetcher(client),
        throttle = RequestThrottle(minIntervalMs = 1_000L, clock = { PlatformClock.nowMs() }),
    )

    private val kuwo: KuwoSource = KuwoSource(
        fetcher = IosJsonFetcher(client),
        throttle = RequestThrottle(minIntervalMs = 1_000L, clock = { PlatformClock.nowMs() }),
    )

    // ---------- 会员状态（v1.4.4） ----------

    private val vipThrottle = RequestThrottle(minIntervalMs = 1_000L, clock = { PlatformClock.nowMs() })
    private val vipFetcher: JsonFetcher = IosJsonFetcher(client)

    /**
     * 查当前账号会员等级。
     *
     * **绝不抛异常**：任何失败都返回 VipTier.Unknown，
     * 因为界面上「不知道」比「胡说会员」安全。
     * Swift 侧拿到的就是这个 data class，不会碰 NSError 桥接。
     */
    suspend fun vipStatusSafe(): VipStatus = try {
        VipStatusResolver.resolve(vipFetcher, vipThrottle, cookies)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        VipStatus(VipTier.Unknown, source = "api-error")
    }

    /**
     * WebView 路线的结果回填（可选）。
     * 接口全部失败时，壳用 WebView 打开会员页读 DOM，读到文本后调这个就能统一归类。
     */
    fun vipTierFromText(text: String): VipTier = VipStatusResolver.tierOfText(text)

    /** 今天日期（㌉分用：判绝有效期是不是过了） */
    fun setToday(dateText: String) {
        VipStatusResolver.todayProvider = { dateText }
    }

    /** 可用源列表（名字 + id），UI 用来做源选择 */
    fun availableSources(): List<Pair<String, String>> = listOf(
        "喜马拉雅（免登录）" to "ximalaya-open",
        "酷我听书" to "kuwo",
        "喜马拉雅（登录版）" to "ximalaya",
    )

    /** 免登录源搜索。sourceId 见 availableSources()。 */
    suspend fun searchBySource(sourceId: String, keywords: String, page: Int): SearchResult = try {
        when (sourceId) {
            "kuwo" -> kuwo.search(keywords, page)
            "ximalaya-open" -> xmOpen.search(keywords, page)
            else -> engine.search(keywords, page)
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: SourceErrors) {
        SearchResult(books = emptyList(), maxPage = 0, source = "error", page = page, hint = describe(e))
    } catch (e: Throwable) {
        // K/N 头文件写明 Other uncaught Kotlin exceptions are fatal：
        // 这层不兜住，KuwoSource 里 resp as FetchOutcome.Failed 之类的硬转会直接 abort 进程。
        SearchResult(books = emptyList(), maxPage = 0, source = "error", page = page,
            hint = "搜索异常：" + (e.message ?: e::class.simpleName ?: "未知"))
    }

    /** 免登录源详情（不抛版本）。 */
    suspend fun detailBySourceSafe(sourceId: String, bookUrl: String, loadEpisodes: Boolean = true): BookDetailResult =
        try {
            val d = when (sourceId) {
                "kuwo" -> kuwo.bookDetail(bookUrl, loadEpisodes, false)
                "ximalaya-open" -> xmOpen.bookDetail(bookUrl, loadEpisodes, false)
                else -> engine.bookDetail(bookUrl, loadEpisodes, false)
            }
            BookDetailResult(detail = d, reason = null)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SourceErrors) {
            BookDetailResult(detail = null, reason = describe(e))
        } catch (e: Throwable) {
            BookDetailResult(detail = null, reason = "详情解析失败：" + (e.message ?: e::class.simpleName ?: "未知"))
        }

    /** 免登录源取播放地址（不抛版本）。 */
    suspend fun audioBySourceSafe(sourceId: String, url: String): AudioResult =
        try {
            val a = when (sourceId) {
                "kuwo" -> kuwo.audioExtractor().extract(url)
                "ximalaya-open" -> xmOpen.audioExtractor().extract(url)
                else -> engine.audioExtractor().extract(url)
            }
            AudioResult(audio = a, reason = null)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SourceErrors) {
            AudioResult(audio = null, reason = describe(e))
        } catch (e: Throwable) {
            AudioResult(audio = null, reason = "解析地址失败：" + (e.message ?: e::class.simpleName ?: "未知"))
        }

    /** 解析专辑 ID（/album/{id}、?albumId=、纯数字 ≥4 位）。 */
    fun parseAlbumId(bookUrl: String): Long = engine.parseAlbumId(bookUrl) ?: 0L

    fun close() { client.close() }

    private fun describe(e: SourceErrors): String = when (e) {
        is SourceErrors.NotFound -> "没有找到该资源"
        is SourceErrors.ParseFailed -> "解析失败：" + e.reason
        is SourceErrors.RateLimited -> "触发限流，稍后再试，不硬冲"
        is SourceErrors.Network -> "网络异常：" + e.reason
        is SourceErrors.Auth -> "登录态失效，请重新登录"
        is SourceErrors.Vip -> e.reason
        is SourceErrors.Upstream -> "上游服务异常（HTTP " + e.status + "）"
    }
}
