package com.local.audiobook.core

import com.local.audiobook.core.engine.TemplateTingSite
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 模板站搜索契约（R6 新增）。
 * 背景：搜不到时曾经用「分类前 10 本」冒充结果，用户搜乱码也看到当红书，误以为搜到了。
 */
class TemplateSearchContractTest {

    private class Page(private val html: String) : JsonFetcher {
        override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome =
            FetchOutcome.Ok(200, html)
    }

    private fun site(html: String) = TemplateTingSite(
        fetcher = Page(html),
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        sourceId = "test",
        base = "https://example.com",
        siteName = "test",
        bookHrefPattern = "/(\\d+)\\.html",
        cats = listOf("首页" to "https://example.com/"),
    )

    private val page = """
        <a href="/1.html" title="斗罗大陆">斗罗大陆</a>
        <a href="/2.html" title="守拙归田园">守拙归田园</a>
        <a href="/3.html" title="三体">三体</a>
    """.trimIndent()

    @Test
    fun noMatchReturnsEmptyNotFakeResults() = runBlocking {
        val r = site(page).search("zzzz不存在词", 1)
        assertTrue(r.books.isEmpty(),
            "搜不到必须返回空，不能用分类书冒充。实际返回 " + r.books.size + " 本")
        assertTrue(!r.hint.isNullOrEmpty(), "空结果必须给提示")
        assertTrue(r.hint!!.contains("zzzz不存在词"), "提示里要带关键词，让用户知道搜的是什么")
    }

    @Test
    fun matchingStillWorks() = runBlocking {
        val r = site(page).search("斗罗", 1)
        assertEquals(1, r.books.size)
        assertEquals("斗罗大陆", r.books[0].title)
    }

    @Test
    fun emptyKeywordGivesBrowsableList() = runBlocking {
        // 关键词为空是「随便看看」语义，可以给列表
        val r = site(page).search("", 1)
        assertEquals(3, r.books.size, "空关键词应返回分类书单")
    }

    @Test
    fun searchDoesNotCrashOnSpecialChars() = runBlocking {
        for (kw in listOf("📚🎧", "'; DROP TABLE--", "。。", "a".repeat(120))) {
            val r = site(page).search(kw, 1)
            assertTrue(r.books.isEmpty() || r.books.isNotEmpty())  // 不崩即可
        }
    }
}
