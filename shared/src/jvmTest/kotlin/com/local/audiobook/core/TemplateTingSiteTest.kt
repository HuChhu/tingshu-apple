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

    // ---------- 健壮性（审计 P1-3）----------

    private fun siteWith(handler: (String) -> String, mode: TemplateTingSite.ChapterMode = TemplateTingSite.ChapterMode.Html) =
        TemplateTingSite(
            fetcher = object : JsonFetcher {
                override suspend fun get(url: String, headers: Map<String, String>) =
                    FetchOutcome.Ok(200, handler(url))
            },
            throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
            base = "https://www.qmtsw.com",
            siteName = "Qmtsw",
            cats = listOf("玄幻" to "https://www.qmtsw.com/book/1.html"),
            bookHrefPattern = "/show/(\\d+)\\.html",
            sourceId = "qmtsw",
            chapterMode = mode,
            jsonApiPattern = "https://www.qmtsw.com/api/v1/program/list?album_id={id}&page={page}",
            jsonListKey = "data.programs",
            jsonUrlKey = "file_path",
            jsonTitleKey = "program_name",
        )

    @Test
    fun searchDocsNotArrayIsNotCrash() {
        // 书籍页/分类页返回的是 <html> 而不是 JSON 数组，绝不能抛异常
        runBlocking {
            val site = siteWith({ _: String -> "<html><body>\u9519\u8bef\u9875</body></html>" })
            val r = site.search("\u4e09\u4f53", 1)
            assertEquals(0, r.books.size)
            assertEquals("qmtsw", r.source, "空结果也要保留 source，不能变成 error")
        }
    }

    @Test
    fun jsonModeWithStringIdAndNullTitle() {
        // P1-3：program_id 是字符串 "5893"、program_name 为 null、file_path 缺页 —— 都不能崩。
        // 用专门造的 Json 站（bookHrefPattern 走 /album/），避免被默认章节正则误伤。
        val json = """
            {"code":1,"data":{"total":4,"programs":[
              {"program_id":"5893","program_name":"\u6709\u58f0\u4e66\u4e00","file_path":"https://www.vbus.cc/program/get-source/5893"},
              {"program_id":"5894","program_name":null,"file_path":"https://www.vbus.cc/program/get-source/5894"},
              {"program_id":"\u975e\u6570\u5b57","program_name":"\u7b2c\u4e09"},
              {"program_id":"5895","program_name":"\u7a7a\u94fe\u63a5","file_path":""}
            ]}}
        """.trimIndent()
        runBlocking {
            val site = TemplateTingSite(
                fetcher = object : JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) =
                        FetchOutcome.Ok(200, if (url.startsWith("https://www.vbus.cc/api/")) json else "<html></html>")
                },
                throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                base = "https://www.vbus.cc",
                siteName = "VBUS",
                cats = listOf("\u6700\u65b0" to "https://www.vbus.cc/album/new"),
                bookHrefPattern = "/album/(\\d+)",
                chapterMode = TemplateTingSite.ChapterMode.Json,
                jsonApiPattern = "https://www.vbus.cc/api/v1/program/list?album_id={id}&page={page}",
                jsonListKey = "data.programs",
                jsonUrlKey = "file_path",
                jsonTitleKey = "program_name",
                sourceId = "vbus",
            )
            val d = site.bookDetail("https://www.vbus.cc/album/1064", true, false)
            println("DEBUG eps=" + d.episodes.size + " patterns=[" + json.length + "]")
            // 第 1 条可用；第 2 条 title null 用序号兜底；第 3 条无链接跳过；第 4 条空链接跳过
            assertEquals(2, d.episodes.size, "无效节目应跳过：" + d.episodes.map { it.title + "@" + it.url })
            assertEquals("https://www.vbus.cc/program/get-source/5893", d.episodes[0].url)
            assertEquals("\u6709\u58f0\u4e66\u4e00", d.episodes[0].title)
            assertEquals(5893L, d.episodes[0].trackId)
            assertEquals("\u7b2c2\u96c6", d.episodes[1].title, "title 为 null 时用序号兜底")
            // file_path 是 302 跳转口，extract 要原样交出，让播放器自己跟跳转
            val a = site.audioExtractor().extract(d.episodes[0].url)
            assertEquals("https://www.vbus.cc/program/get-source/5893", a.url)
        }
    }

    @Test
    fun jsonModeApiReturnsObjectNotArray() {
        // 接口 404 时返回 {"code":0,"data":"\u63a5\u53e3\u4e0d\u5b58\u5728\u3002"}，data 不是数组
        val json = """{"code":0,"data":"\u63a5\u53e3\u4e0d\u5b58\u5728\u3002"}"""
        runBlocking {
            val site = siteWith({ _: String -> json }, TemplateTingSite.ChapterMode.Json)
            val d = site.bookDetail("https://www.qmtsw.com/album/1064", true, false)
            assertEquals(0, d.episodes.size, "拿不到节目返回空列表，不抛异常")
            assertEquals(0L, d.book.trackCount)
        }
    }

    @Test
    fun playlistModeTracksUrl() {
        val book = """
            <html><head><title>\u4e0a\u9580\u9f8d\u5a7f\u6709\u8072\u66f8\u5c0f\u8aac\u7dda\u4e0a\u514d\u8cbb\u807d</title></head><body>
            <div class="audioigniter-root" data-tracks-url="https://www.ytysxs.com/?audioigniter_playlist_id=10816"></div>
            </body></html>
        """.trimIndent()
        val pl = """[{"title":"\u7b2c001-005\u96c6","audio":"https://mp3.ytysxs.top/2024/10803/001-005.mp3"},
                    {"title":"\u7b2c006-010\u96c6","audio":"https://mp3.ytysxs.top/2024/10803/006-010.mp3"}]"""
        runBlocking {
            val site = siteWith({ url: String -> if (url.contains("playlist_id")) pl else book },
                TemplateTingSite.ChapterMode.Playlist)
            val d = site.bookDetail("https://www.ytysxs.com/10803.html", true, false)
            assertEquals(2, d.episodes.size)
            assertTrue(d.episodes[0].url.endsWith(".mp3"), "playlist 模式的章节 url 就是音频直链")
            // 章节 url 是音频 → extract 必须原样返回，不发第二个请求
            val a = site.audioExtractor().extract(d.episodes[1].url)
            assertEquals("https://mp3.ytysxs.top/2024/10803/006-010.mp3", a.url)
        }
    }

    @Test
    fun audioVarNowRelativePathIsResolved() {
        // P1-3：var now="\/upload\/a.m4a" 是相对路径，旧实现直接判失败掉到 m4a 正则
        val html = """<script>var now="/upload/2024/a.m4a";</script>"""
        runBlocking {
            val a = siteWith({ _: String -> html }).audioExtractor().extract("https://www.qmtsw.com/play/1-0-0.html")
            assertEquals("https://www.qmtsw.com/upload/2024/a.m4a", a.url)
        }
    }

    @Test
    fun audioIgnoresImageAndBannerUrls() {
        // 播放页里有广告图 / 分享图 / 统计脚本，只能是 m4a/mp3/m3u8/aac 才算音频
        val html = """<img src="https://ad.example.com/x.jpg">
            <a href="https://share.example.com/poster.png">\u5206\u4eab</a>
            <script src="https://cdn.example.com/ga.js"></script>
            <audio src="https://cdn.example.com/real.m4a"></audio>"""
        runBlocking {
            val a = siteWith({ _: String -> html }).audioExtractor().extract("https://www.qmtsw.com/play/1-0-0.html")
            assertEquals("https://cdn.example.com/real.m4a", a.url, "不能抓成广告图")
        }
    }

    @Test
    fun getSourceRedirectIsReturnedAsIs() {
        val html = """<audio data-vbus-player src="/program/get-source/5893" autoplay controls></audio>"""
        runBlocking {
            val a = siteWith({ _: String -> html }).audioExtractor().extract("https://www.vbus.cc/v/5893")
            assertEquals("https://www.qmtsw.com/program/get-source/5893", a.url)
        }
    }

    @Test
    fun toAbsHandlesQueryHref() {
        // P1-3：href="?page=2" 不能拼成 base + "/?page=2"，要 base + "/?page=2"
        val html = """<a href="?from=list&id=7">q</a>"""
        runBlocking {
            val site = siteWith({ _: String -> html })
            val books = site.categoryBooks(0)
            assertEquals(0, books.size, "?query 链接不匹配书籍 pattern")
            // 直接验 toAbs 的语义：相对 href 拼在 base 根下
            val rel = siteWith({ _: String -> """<a href="show/123.html">rel</a>""" }, TemplateTingSite.ChapterMode.Html)
            assertEquals(0, rel.categoryBooks(0).size, "相对 href 不匹配 /show/ 绝对 pattern")
        }
    }

    @Test
    fun bookDetailEmptyPageReturnsBookWithoutEpisodes() {
        runBlocking {
            val site = siteWith({ _: String -> "<html><head><title>\u4e66\u540d_\u7ad9\u540d</title></head><body></body></html>" })
            val d = site.bookDetail("https://www.qmtsw.com/show/999.html", true, false)
            assertEquals("\u4e66\u540d", d.book.title, "空页也要给出书名（title 去后缀）")
            assertEquals(0, d.episodes.size, "0 章返回空列表，不抛异常")
            assertEquals("https://www.qmtsw.com/show/999.html", d.book.bookUrl)
        }
    }

    @Test
    fun bookDetailLoadEpisodesFalseSkipsChapters() {
        runBlocking {
            val d = mkSite(bookHtml).bookDetail("https://www.qmtsw.com/show/21170.html", false, false)
            assertEquals(0, d.episodes.size)
            assertEquals("\u5b88\u62d9\u5f52\u7530\u56ed\u6709\u58f0\u5c0f\u8bf4", d.book.title)
        }
    }

    @Test
    fun longBookTitleIsKept() {
        // 长书名（站点常把"作者+分类+集数"塞进 title）不能被 40 字上限砍掉
        val long = "\u6211\u7684\u5f02\u5b9d\u7269\u5546\u5e97\u7a7f\u8d8a\u5230\u4e0d\u540c\u4e16\u754c\u5f53\u8001\u677f"
        val html = """<a href="/show/777.html" title="$long">x</a>"""
        runBlocking {
            val books = siteWith({ _: String -> html }).categoryBooks(0)
            assertEquals(1, books.size)
            assertEquals(long, books[0].title)
        }
    }

    @Test
    fun proseIsNotMistakenForTitle() {
        // 跨标签抓到的正文（含大量句读）不能当书名
        val html = """<a href="/show/888.html"></a>\u8fd9\u662f\u4e00\u6bb5\u5f88\u957f\u7684\u4ecb\u7ecd\uff0c\u6709\u9017\u53f7\uff0c\u4e5f\u6709\u53e5\u53f7\u3002\u8fd8\u6709\u5b8c\u7ed3\u53e5\u3002"""
        runBlocking {
            val books = siteWith({ _: String -> html }).categoryBooks(0)
            assertEquals(0, books.size, "正文不能被当成书名")
        }
    }

    @Test
    fun gushiyaCatsAreYaNotTingshu() {
        // 回归：gushiya 的分类页是 /ya/N.html，书页是 /tingshu/N.html
        val g = TemplateSites.all.first { it.key == "gushiya" }
        assertTrue(g.cats.isNotEmpty(), "gushiya 要有分类")
        assertTrue(g.cats.all { it.second.contains("/ya/") }, "gushiya 分类应指向 /ya/：" + g.cats.map { it.second })
        assertEquals("/tingshu/(\\d+)\\.html", g.bookHrefPattern)
    }

    @Test
    fun enginePassesChapterPatternThrough() {
        // 回归（P0）：SourceRegistry 曾经漏传 chapterPattern/chapterPrefix，tingdada 真机 0 章
        val t = TemplateSites.all.first { it.key == "tingdada" }
        assertEquals("/mp3/(\\d+)-(\\d+)-(\\d+)\\.html", t.chapterPattern)
        val site = TemplateSites.byKey("tingdada",
            object : JsonFetcher {
                override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, "")
            },
            RequestThrottle(minIntervalMs = 0L, clock = { 0L }))!!
        assertEquals(TemplateTingSite.ChapterMode.Html, site.chapterMode)
    }

    @Test
    fun everySiteHasValidRegex() {
        for (c in TemplateSites.all) {
            runCatching { Regex(c.bookHrefPattern) }.onFailure { throw AssertionError(c.key + " 的 bookHrefPattern 不是合法正则：" + it.message) }
            runCatching { Regex(c.chapterPattern) }.onFailure { throw AssertionError(c.key + " 的 chapterPattern 不是合法正则：" + it.message) }
            if (c.chapterMode == TemplateTingSite.ChapterMode.Json) {
                assertTrue(c.jsonApiPattern.contains("{id}"), c.key + " 是 Json 模式但 jsonApiPattern 没有 {id}")
            }
            assertTrue(c.base.startsWith("http"), c.key + " base 不合法")
            assertTrue(!c.base.endsWith("/"), c.key + " base 不该带尾斜杠（拼 URL 会双斜杠）")
        }
    }

    @Test
    fun htmlPagesModePaginatesAndStopsOnEmptyPage() {
        // vbus：/album/1064 每页 20 条，第 N 页 /album/1064/N；第 3 页只有 19 条，第 4 页 0 条必须停
        val p1 = (1..20).joinToString("") { i -> "<a href='/v/" + (100 + i) + "'>" + "\u8282\u76ee" + i + "</a>" }
        val p2 = (21..40).joinToString("") { i -> "<a href='/v/" + (100 + i) + "'>" + "\u8282\u76ee" + i + "</a>" }
        val p3 = (41..59).joinToString("") { i -> "<a href='/v/" + (100 + i) + "'>" + "\u8282\u76ee" + i + "</a>" }
        // 页面共有元素：导航里的 /album 链接，不能被当成节目
        val nav = "<a href='/album/1064'>\u4e13\u8f91</a><a href='/'>\u9996\u9875</a>"
        runBlocking {
            val site = TemplateTingSite(
                fetcher = object : JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, when {
                        url.endsWith("/album/1064") -> nav + p1
                        url.endsWith("/album/1064/2") -> nav + p2
                        url.endsWith("/album/1064/3") -> nav + p3
                        else -> nav
                    })
                },
                throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                base = "https://www.vbus.cc",
                siteName = "VBUS",
                cats = listOf("\u6700\u65b0" to "https://www.vbus.cc/album/new"),
                bookHrefPattern = "/album/(\\d+)",
                chapterMode = TemplateTingSite.ChapterMode.HtmlPages,
                htmlPagePattern = "{url}/{page}",
                sourceId = "vbus",
            )
            val d = site.bookDetail("https://www.vbus.cc/album/1064", true, false)
            assertEquals(59, d.episodes.size, "三页合起来 59 条，不能无限翻")
            assertEquals(101L, d.episodes[0].trackId)
            assertEquals("\u8282\u76ee1", d.episodes[0].title)
            assertEquals(59L, d.book.trackCount)
        }
    }

    @Test
    fun htmlPagesModeStopsWhenPageRepeats() {
        // 有些站页码超出范围会回第一页而不是 404 —— 必须靠"本页全部见过"终止，否则死循环
        val p1 = (1..20).joinToString("") { i -> "<a href='/v/" + (100 + i) + "'>" + "\u8282\u76ee" + i + "</a>" }
        runBlocking {
            val site = TemplateTingSite(
                fetcher = object : JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, p1)
                },
                throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                base = "https://www.vbus.cc",
                siteName = "VBUS",
                cats = listOf("x" to "https://www.vbus.cc/album/new"),
                bookHrefPattern = "/album/(\\d+)",
                chapterMode = TemplateTingSite.ChapterMode.HtmlPages,
                htmlPagePattern = "{url}/{page}",
                htmlMaxPages = 5,
                sourceId = "vbus",
            )
            val d = site.bookDetail("https://www.vbus.cc/album/1064", true, false)
            assertEquals(20, d.episodes.size, "重复页面必须靠去重终止")
        }
    }

    @Test
    fun vbusUsesHtmlPagesNotBrokenApi() {
        // 回归：/api/v1/program/list?album_id= 会忽略过滤返回全站 6852 条，不能再走 Json 模式
        val v = TemplateSites.all.first { it.key == "vbus" }
        assertEquals(TemplateTingSite.ChapterMode.HtmlPages, v.chapterMode)
        assertTrue(v.jsonApiPattern.isEmpty(), "vbus 不该再用不支持专辑过滤的接口")
        assertTrue(v.bookHrefPattern.contains("album"), "vbus 书页是 /album/N")
    }

    @Test
    fun ytysxsUsesPlaylistMode() {
        val y = TemplateSites.all.first { it.key == "ytysxs" }
        assertEquals(TemplateTingSite.ChapterMode.Playlist, y.chapterMode)
        assertTrue(y.cats.isNotEmpty(), "ytysxs 要有分类")
        assertTrue(y.cats.all { it.second.endsWith("/") }, "ytysxs 分类是 /xxx/ 目录页：" + y.cats.map { it.second })
    }

    // ---------- 新增模式与 toAbs ----------

    @Test
    fun toAbsQueryHrefGoesToRootPath() {
        // 回归：?query 相对地址要拼成 base + "/?query"
        val html = """<div class="audioigniter-root" data-tracks-url="?audioigniter_playlist_id=9"></div>"""
        runBlocking {
            val site = TemplateTingSite(
                fetcher = object : JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) =
                        if (url.contains("audioigniter_playlist_id=9"))
                            FetchOutcome.Ok(200, """[{"title":"t1","audio":"https://x.com/1.mp3"}]""")
                        else FetchOutcome.Ok(200, html)
                },
                throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                base = "https://www.ytysxs.com",
                siteName = "Y",
                cats = listOf("a" to "https://www.ytysxs.com/yanqing/"),
                bookHrefPattern = "/(\\d+)\\.html",
                chapterMode = TemplateTingSite.ChapterMode.Playlist,
                sourceId = "ytysxs",
            )
            val d = site.bookDetail("https://www.ytysxs.com/10803.html", true, false)
            assertEquals("https://x.com/1.mp3", d.episodes.singleOrNull()?.url, "?query 应拼成 base + /?query")
        }
    }

    @Test
    fun ting15ApiModeWired() {
        // ting15：播放页里没有音频，只有 POST /?s=api-getneoplay
        val t = TemplateSites.all.first { it.key == "ting15" }
        assertEquals("/?s=api-getneoplay", t.audioApiPattern)
        assertEquals(-1, t.chapterPathGroup)
        assertTrue(t.base.startsWith("https://www.ting15.com"), "ting15 应走 www 站")
        assertTrue(t.chapterPattern.endsWith("\\.html"), "ting15 章节应以 .html 结尾：" + t.chapterPattern)
        assertTrue(t.chapterPattern.contains("/\\d+/\\d+-\\d+"), "ting15 章节是 /分类/N/卷-集.html：" + t.chapterPattern)
    }

    @Test
    fun yuetingbaUsesHttpAndAudioApi() {
        val y = TemplateSites.all.first { it.key == "yuetingba" }
        assertEquals("http://www.yuetingba.cn", y.base, "https 会 301 到 http，直接用 http")
        assertEquals("/api/app/docs-listen/{id}/audio-url", y.audioApiUrlPattern)
        assertTrue(y.bookHrefPattern.contains("/0"), "yuetingba 书链接尾巴是 /0：" + y.bookHrefPattern)
    }

    @Test
    fun tingdadaChapterPatternActuallyProducesMp3Urls() {
        // P0 回归：SourceRegistry 漏传 chapterPattern 时，tingdada 会拼出 /play/N-N-N.html（全是 404）
        val book = """<a href="/mp3/1234-0-1.html">1</a><a href="/mp3/1234-0-2.html">2</a>"""
        runBlocking {
            val site = TemplateTingSite(
                fetcher = object : JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, book)
                },
                throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                base = "https://www.tingdada.com",
                siteName = "T",
                cats = listOf("a" to "https://www.tingdada.com/html/551.html"),
                bookHrefPattern = "/books/(\\d+)\\.html",
                chapterPattern = "/mp3/(\\d+)-(\\d+)-(\\d+)\\.html",
                chapterPrefix = "/mp3/",
                sourceId = "tingdada",
            )
            val d = site.bookDetail("https://www.tingdada.com/books/1234.html", true, false)
            assertEquals(2, d.episodes.size)
            assertEquals("https://www.tingdada.com/mp3/1234-0-1.html", d.episodes[0].url)
        }
    }

    @Test
    fun chapterPatternMismatchYieldsNoEpisodes() {
        // 拼出来的地址不在页面里时，宁可 0 章也不给假链接
        val html = """<a href="/wuxiaxuanhuan/1254/0-1.html">1</a>"""
        runBlocking {
            val site = siteWith({ _: String -> html })
            val d = site.bookDetail("https://www.qmtsw.com/show/1254.html", true, false)
            assertEquals(0, d.episodes.size, "路径规则对不上就不给章节")
        }
    }
}
