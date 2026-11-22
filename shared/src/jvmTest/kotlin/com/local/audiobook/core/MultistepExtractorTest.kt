package com.local.audiobook.core

import com.local.audiobook.core.engine.MultistepAudioExtractor
import com.local.audiobook.core.engine.MultistepAudioExtractor.ExtractError
import com.local.audiobook.core.engine.MultistepAudioExtractor.Level
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 多级提取器单测 —— 纯函数，零网络。
 * 覆盖每一级的正例、错例，以及「全失败必须报错，不许猜地址」的纪律。
 */
class MultistepExtractorTest {

    // ---------- 级 1：直链 ----------

    @Test
    fun directM4aIsLevel1() {
        val hit = MultistepAudioExtractor.tryDirect("https://a.b.com/x/1.m4a")
        assertNotNull(hit)
        assertEquals(Level.Direct, hit.level)
        assertEquals("https://a.b.com/x/1.m4a", hit.url)
    }

    @Test
    fun directWithQueryStringStillMatches() {
        val hit = MultistepAudioExtractor.tryDirect("https://a.b.com/1.mp3?token=abc&x=1")
        assertNotNull(hit)
        assertEquals(Level.Direct, hit.level)
    }

    @Test
    fun directAllExtensionsCovered() {
        listOf("m4a", "mp3", "aac", "flac", "m3u8").forEach { ext ->
            assertNotNull(
                MultistepAudioExtractor.tryDirect("https://a.com/1.$ext"),
                "扩展名 $ext 应被识别为直链"
            )
        }
    }

    @Test
    fun pageUrlIsNotDirect() {
        assertNull(MultistepAudioExtractor.tryDirect("https://a.com/book/123"))
    }

    @Test
    fun nonHttpIsNotDirect() {
        assertNull(MultistepAudioExtractor.tryDirect("/local/1.mp3"))
        assertNull(MultistepAudioExtractor.tryDirect(""))
    }

    @Test
    fun directHitCarriesHostHeaders() {
        val hit = MultistepAudioExtractor.tryDirect("https://audio.xmcdn.com/1.m4a")
        assertNotNull(hit)
        assertTrue(hit.headers.isNotEmpty(), "喜马拉雅 CDN 应注入 headers")

        val other = MultistepAudioExtractor.tryDirect("https://random.example/1.m4a")
        assertNotNull(other)
        assertTrue(other.headers.isEmpty(), "未知域不应带 headers")
    }

    // ---------- 级 2：HTML ----------

    @Test
    fun htmlAudioTagIsLevel2() {
        val html = """<html><body><audio id="p" src="https://c.d.com/2.m4a"></audio></body></html>"""
        val hit = MultistepAudioExtractor.tryHtml(html)
        assertNotNull(hit)
        assertEquals(Level.Html, hit.level)
        assertEquals("https://c.d.com/2.m4a", hit.url)
    }

    @Test
    fun htmlSourceTagIsLevel2() {
        val html = """<video><source src='https://c.d.com/3.mp3' type="audio/mpeg"></video>"""
        val hit = MultistepAudioExtractor.tryHtml(html)
        assertNotNull(hit)
        assertEquals("https://c.d.com/3.mp3", hit.url)
    }

    @Test
    fun htmlJsVariableIsLevel2() {
        val html = """<script>var url = "https://c.d.com/4.m4a?sign=x";</script>"""
        val hit = MultistepAudioExtractor.tryHtml(html)
        assertNotNull(hit)
        assertEquals("https://c.d.com/4.m4a?sign=x", hit.url)
    }

    @Test
    fun htmlWithoutAudioReturnsNull() {
        assertNull(MultistepAudioExtractor.tryHtml("<html><body>no audio here</body></html>"))
        assertNull(MultistepAudioExtractor.tryHtml(""))
    }

    // ---------- 级 3：JSON ----------

    @Test
    fun jsonPlayUrlIsLevel3() {
        val json = """{"ret":200,"data":{"playUrl":"https://f.g.com/6.m4a"}}"""
        val hit = MultistepAudioExtractor.tryJson(json)
        assertNotNull(hit)
        assertEquals(Level.Json, hit.level)
        assertEquals("https://f.g.com/6.m4a", hit.url)
    }

    @Test
    fun jsonFieldPriorityOrder() {
        val json = """{"url":"https://x.com/a.mp3","playUrl":"https://y.com/b.m4a"}"""
        val hit = MultistepAudioExtractor.tryJson(json)
        assertNotNull(hit)
        assertEquals("https://y.com/b.m4a", hit.url, "playUrl 优先级应高于 url")
    }

    @Test
    fun jsonSnakeCaseFieldWorks() {
        val json = """{"data":{"play_url":"https://h.i.com/7.mp3"}}"""
        val hit = MultistepAudioExtractor.tryJson(json)
        assertNotNull(hit)
        assertEquals("https://h.i.com/7.mp3", hit.url)
    }

    @Test
    fun nonJsonReturnsNull() {
        assertNull(MultistepAudioExtractor.tryJson("<html></html>"))
        assertNull(MultistepAudioExtractor.tryJson(""))
    }

    // ---------- 级 4：自定义 ----------

    @Test
    fun customRuleIsLevel4() {
        val hit = MultistepAudioExtractor.tryCustom("raw body") { "https://j.k.com/8.m4a" }
        assertNotNull(hit)
        assertEquals(Level.Custom, hit.level)
    }

    @Test
    fun customRuleReturningNullMeansMiss() {
        assertNull(MultistepAudioExtractor.tryCustom("body") { null })
        assertNull(MultistepAudioExtractor.tryCustom("body", null))
    }

    @Test
    fun customRuleNonHttpRejected() {
        assertNull(MultistepAudioExtractor.tryCustom("body") { "/relative/path.m4a" })
    }

    // ---------- 编排：命中即停 ----------

    @Test
    fun directWinsWithoutFetching() {
        runBlocking {
            var fetched = false
            val hit = MultistepAudioExtractor.extract(
                raw = "https://a.com/1.m4a",
                bodyFetcher = { fetched = true; null }
            )
            assertEquals(Level.Direct, hit.level)
            assertTrue(!fetched, "级1命中后不应再取正文")
        }
    }

    @Test
    fun fallsToHtmlWhenNotDirect() {
        runBlocking {
            val hit = MultistepAudioExtractor.extract(
                raw = "https://a.com/book/1",
                bodyFetcher = { """<audio src="https://b.com/2.m4a"></audio>""" }
            )
            assertEquals(Level.Html, hit.level)
        }
    }

    @Test
    fun fallsToJsonWhenNoHtml() {
        runBlocking {
            val hit = MultistepAudioExtractor.extract(
                raw = "https://a.com/api/1",
                bodyFetcher = { """{"playUrl":"https://b.com/3.m4a"}""" }
            )
            assertEquals(Level.Json, hit.level)
        }
    }

    @Test
    fun fallsToCustomLast() {
        runBlocking {
            val hit = MultistepAudioExtractor.extract(
                raw = "https://a.com/enc/1",
                bodyFetcher = { "encrypted-payload" },
                customRule = { "https://b.com/4.m4a" }
            )
            assertEquals(Level.Custom, hit.level)
        }
    }

    @Test
    fun allFailThrowsNeedsWebView() {
        runBlocking {
            assertFailsWith<ExtractError.NeedsWebView> {
                MultistepAudioExtractor.extract(
                    raw = "https://a.com/page",
                    bodyFetcher = { "<html>nothing</html>" }
                )
            }
        }
    }

    @Test
    fun fetchFailureThrowsAllFailed() {
        runBlocking {
            assertFailsWith<ExtractError.AllFailed> {
                MultistepAudioExtractor.extract(
                    raw = "https://a.com/page",
                    bodyFetcher = { null }
                )
            }
        }
    }

    @Test
    fun levelNumbersAreAscending() {
        val ordered = MultistepAudioExtractor.Level.entries.sortedBy { it.n }
        assertEquals(
            listOf(Level.Direct, Level.Html, Level.Json, Level.Custom, Level.WebView),
            ordered
        )
    }
}
