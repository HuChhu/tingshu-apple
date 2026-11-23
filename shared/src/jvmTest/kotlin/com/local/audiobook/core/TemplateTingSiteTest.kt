package com.local.audiobook.core

import com.local.audiobook.core.engine.TemplateSites
import com.local.audiobook.core.engine.TemplateTingSite
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 模板站引擎测试。
 *
 * HTML 样本来自 qmtsw.com 实测页面（2026-11-23），
 * 结构：分类页 /book/N.html → 书籍页 /show/N.html → 播放页 /play/N-0-N.html
 */
class TemplateTingSiteTest {

    // 分类页样本（简化）
    private val catHtml = """
        <html><body>
        <a href="/book/1.html">玄幻</a>
        <a href="/show/21170.html">守拙归田园</a>
        <a href="/show/21171.html">少年御灵师</a>
        <a href="/show/21172.html">我在仙界淘废品</a>
        <a href="/about.html">关于</a>
        </body></html>
    """.trimIndent()

    // 书籍页样本
    private val bookHtml = """
        <html><head><title>守拙归田园有声小说_在线收听</title></head><body>
        <p>作者：中文听见</p>
        <img src="/cover/1.jpg">
        <a href="/play/21170-0-0.html">第1集</a>
        <a href="/play/21170-0-1.html">第2集</a>
        <a href="/play/21170-0-2.html">第3集</a>
        </body></html>
    """.trimIndent()

    // 播放页样本
    private val playHtml = """
        <html><body>
        <script>var now="https://aod.cos.tx.xmcdn.com/storages/x/1.m4a";</script>
        </body></html>
    """.trimIndent()

    private fun mkSite(html: String) = TemplateTingSite(
        fetcher = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) =
                FetchOutcome.Ok(200, html)
        },
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        base = "https://www.qmtsw.com",
        siteName = "Qmtsw",
        cats = listOf("玄幻" to "https://www.qmtsw.com/book/1.html"),
        bookHrefPattern = "/show/(\\d+)\\.html",
        chapterPattern = "/play/(\\d+)-(\\d+)-(\\d+)\\.html",
        sourceId = "qmtsw",
    )

    @Test
    fun categoryParsesBooksOnly() {
        runBlocking {
            val many = mkSite(catHtml)
            val books = many.categoryBooks(0)
            // 分类页有 4 个链接，但只有 3 个匹配 /show/N.html
            assertEquals(3, books.size, "应该只抓 /show/ 的书籍链接，不抓 /book/ 分类")
            assertEquals("守拙归田园", books[0].title)
            assertEquals("https://www.qmtsw.com/show/21170.html", books[0].bookUrl)
        }
    }

    @Test
    fun categoryIgnoresNonBookLinks() {
        runBlocking {
            val site = mkSite(catHtml)
            val books = site.categoryBooks(0)
            assertTrue(books.none { it.title == "玄幻" }, "分类链接不应被当成书")
            assertTrue(books.none { it.title == "关于" }, "普通链接不应被当成书")
        }
    }

    @Test
    fun detailParsesTitleAndChapters() {
        runBlocking {
            val site = mkSite(bookHtml)
            val d = site.bookDetail("https://www.qmtsw.com/show/21170.html", true, false)
            assertTrue(d.book.title.contains("守拙归田园"), "标题应包含书名：" + d.book.title)
            assertEquals(3, d.episodes.size)
            assertEquals("https://www.qmtsw.com/play/21170-0-0.html", d.episodes[0].url)
            assertEquals(3L, d.book.trackCount, "集数应更新为 3")
        }
    }

    @Test
    fun detailDedupsRepeatedChapterLinks() {
        // 真实页面里同一集会出现多次，必须去重
        val dup = bookHtml.replace(
            "</body>",
            "<a href=\"/play/21170-0-0.html\">重复</a></body>"
        )
        runBlocking {
            val d = mkSite(dup).bookDetail("https://www.qmtsw.com/show/21170.html", true, false)
            assertEquals(3, d.episodes.size, "重复章节链接应去重")
        }
    }

    @Test
    fun audioExtractsFromVarNow() {
        runBlocking {
            val site = mkSite(playHtml)
            val a = site.audioExtractor().extract("https://www.qmtsw.com/play/21170-0-0.html")
            assertEquals("https://aod.cos.tx.xmcdn.com/storages/x/1.m4a", a.url)
        }
    }

    @Test
    fun audioFallsBackToM4aRegex() {
        val noVar = """<html><body><audio src="https://x.com/a.m4a"></audio></body></html>"""
        runBlocking {
            val a = mkSite(noVar).audioExtractor().extract("https://www.qmtsw.com/play/1-0-0.html")
            assertTrue(a.url.endsWith(".m4a"))
        }
    }

    @Test
    fun audioFallsBackToMp3Regex() {
        val mp3 = """<html><body><a href="https://x.com/b.mp3">play</a></body></html>"""
        runBlocking {
            val a = mkSite(mp3).audioExtractor().extract("https://www.qmtsw.com/play/1-0-0.html")
            assertTrue(a.url.endsWith(".mp3"))
        }
    }

    @Test
    fun audioThrowsWhenNothingFound() {
        val empty = "<html><body>no audio</body></html>"
        runBlocking {
            var threw = false
            try {
                mkSite(empty).audioExtractor().extract("https://www.qmtsw.com/play/1-0-0.html")
            } catch (e: Exception) {
                threw = true
            }
            assertTrue(threw, "找不到音频时应抛错，不猜地址")
        }
    }

    @Test
    fun registryHasSites() {
        assertTrue(TemplateSites.all.size >= 30, "配置表至少应有 30 个站，实际 " + TemplateSites.all.size)
    }

    @Test
    fun registryKeysAreUnique() {
        val keys = TemplateSites.all.map { it.key }
        assertEquals(keys.size, keys.toSet().size, "站点 key 必须唯一")
    }

    @Test
    fun registryAllHaveBaseAndPattern() {
        for (c in TemplateSites.all) {
            assertTrue(c.base.startsWith("http"), c.key + " 的 base 不合法")
            assertTrue(c.bookHrefPattern.contains("("), c.key + " 的 pattern 没捕获组")
        }
    }

    @Test
    fun byKeyFindsSite() {
        val site = TemplateSites.byKey(
            "qmtsw",
            object : JsonFetcher {
                override suspend fun get(url: String, headers: Map<String, String>) =
                    FetchOutcome.Ok(200, "")
            },
            RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        )
        assertNotNull(site)
        assertEquals("Qmtsw", site.siteName)
    }
}
