package com.local.audiobook.core

import com.local.audiobook.core.engine.AudioUrlHeaders
import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * v1.4.9 审计：免登录曲目接口（mobwsa）失败时的降级语义。
 *
 * 两个必须分清的情况：
 *   A. 第一页就没有任何直链 → 该专辑用不了这个接口 → 返回空（让调用方退回登录版）
 *   B. 前几页有、后面页 403 或网络不好 → **已经拿到的页必须保留**，不能因为后面挂了就整体丢弃
 */
class OpenTracksFallbackTest {

    private fun engine(handler: suspend (String) -> FetchOutcome): SearchEngine = SearchEngine(
        fetcher = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) = handler(url)
        },
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        budget = WebSearchBudget(now = { 0L }),
        nowMs = { 0L },
        cookieProvider = object : CookieProvider {
            override suspend fun cookie(): String? = null
            override suspend fun refresh() {}
        },
    )

    private fun page(start: Int, count: Int, withUrl: Boolean = true): String {
        val items = (0 until count).joinToString(",") { i ->
            val n = start + i
            if (withUrl)
                """{"trackId":$n,"title":"\u7b2c$n\u96c6","duration":60,"playUrl64":"https://aod.cos.tx.xmcdn.com/$n.mp3"}"""
            else
                """{"trackId":$n,"title":"\u7b2c$n\u96c6","duration":60}"""
        }
        return """{"ret":0,"totalCount":$count,"maxPageId":50,"list":[$items]}"""
    }

    @Test
    fun laterPageFailureKeepsEarlierPages() = runBlocking {
        // 第一页满 20 条；第二页超时 → 已拿到的 20 条必须保留，不能因为后面挂了就整体丢弃。
        val eng = engine { url ->
            when {
                // v1.4.9：分页参数从 pageNum 改成 pageId（mobwsa 只认 pageId）
                url.contains("pageId=1") || url.contains("pageNum=1") -> FetchOutcome.Ok(200, page(1, 20))
                // 第二页起全部超时（含登录版详情接口），确保只有第一页的 20 条能出来
                else -> FetchOutcome.Failed("Timeout", "")
            }
        }
        val d = eng.bookDetail("https://www.ximalaya.com/album/123", true, true)
        assertEquals(20, d.episodes.size, "第二页失败不能把第一页丢掉")
        assertTrue(d.episodes.all { AudioUrlHeaders.isPlayableAudio(it.url) })
    }

    @Test
    fun firstPageWithoutDirectLinksFallsBackToLoginPath() = runBlocking {
        var sawLoginApi = false
        val eng = engine { url ->
            when {
                url.contains("mobwsa.ximalaya.com") -> FetchOutcome.Ok(200, page(1, 3, withUrl = false))
                url.contains("mobile-album") -> { sawLoginApi = true; FetchOutcome.Failed("Http500", "boom") }
                else -> FetchOutcome.Failed("Http404", "")
            }
        }
        // 第一页无直链 → 应该回退到登录版接口（这里登录版也失败 → 丢 Network）
        var threw = false
        try {
            eng.bookDetail("https://www.ximalaya.com/album/123", true, true)
        } catch (e: SourceErrors) {
            threw = true
        }
        assertTrue(sawLoginApi, "免登录接口不适用时必须真的回退到登录版")
        assertTrue(threw, "两路都不行应报错（不能静默返回空）")
    }

    @Test
    fun mobwsaNetworkErrorFallsBack() = runBlocking {
        var sawLoginApi = false
        val eng = engine { url ->
            when {
                url.contains("mobwsa") -> FetchOutcome.Failed("Timeout", "")
                url.contains("mobile-album") -> {
                    sawLoginApi = true
                    FetchOutcome.Failed("Http500", "")
                }
                else -> FetchOutcome.Failed("Http404", "")
            }
        }
        runCatching { eng.bookDetail("https://www.ximalaya.com/album/123", true, true) }
        assertTrue(sawLoginApi, "免登录接口网络异常也必须回退到登录版")
    }
}
