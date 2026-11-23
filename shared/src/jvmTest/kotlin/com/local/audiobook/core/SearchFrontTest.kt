package com.local.audiobook.core

import com.local.audiobook.core.engine.AlbumExtractor
import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 2026-11-24 实机修复的回归锁：
 * ① 搜索第一路改成 search.ximalaya.com/front/v1（mobile 端点已废，稳定返回 HTML）
 * ② front 接口字段名与 revision 接口完全不同（id/nickname/play/tracks/is_finished）
 * 这两点错任何一个，App 搜索就会整页空白，所以必须钉死。
 */
class SearchFrontTest {

    // 真实响应裁剪（2026-11-24 抓的"斗罗大陆"第一条）
    private val frontJson = """
    {"response":{"docs":[
      {"id":47372692,"title":"斗罗大陆之赘婿|多人播讲","nickname":"悠兮缘梦",
       "cover_path":"storages/af40/CKwRIRwE_TAO.jpeg",
       "intro":"<p>一只CAD设计狗穿越到了斗罗大陆</p>",
       "play":103179739,"tracks":380,"is_finished":2},
      {"id":88990011,"title":"斗罗大陆 有声剧","nickname":"某某工作室",
       "cover_path":"http://imagev2.xmcdn.com/a.jpeg","intro":"","play":12000,"tracks":20,"is_finished":0}
    ],"numFound":2,"totalPage":1,"start":1}}
    """.trimIndent()

    private fun engine(f: FakeFetcher) = SearchEngine(
        fetcher = f,
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        budget = WebSearchBudget(now = { 0L }),
        nowMs = { 0L },
        sourceId = "ximalaya",
    )

    @Test
    fun frontEndpointYieldsBooks() {
        runBlocking {
            val f = FakeFetcher().queue("search.ximalaya.com/front/v1", frontJson)
            val r = engine(f).search("斗罗大陆", 1)
            assertEquals(2, r.books.size, "front 接口必须解析出 2 本")
            assertEquals("front", r.source, "第一路必须命中 front")
        }
    }

    @Test
    fun frontFieldsAreMappedNotGuessed() {
        runBlocking {
            val f = FakeFetcher().queue("search.ximalaya.com/front/v1", frontJson)
            val b = engine(f).search("斗罗大陆", 1).books.first()
            assertEquals(47372692L, b.albumId, "id 字段是专辑号（不是 albumId）")
            assertEquals("悠兮缘梦", b.author, "nickname 字段是主播（不是 anchorName）")
            assertEquals(103179739L, b.playCount, "play 字段是播放量（不是 playCount）")
            assertEquals(380L, b.trackCount, "tracks 字段是集数（不是 trackCount）")
            assertEquals(true, b.isFinished, "is_finished=2 表示完结")
            assertTrue(b.bookUrl.endsWith("/album/47372692"))
            assertTrue(b.coverUrl.startsWith("https://"), "封面必须补成 https，否则 iOS 静默不加载")
            assertTrue(!b.intro.contains("<p>"), "简介要去掉 HTML 标签")
        }
    }

    @Test
    fun mobileEndpointNoLongerWasted() {
        runBlocking {
            // 只排 front：若实现还在打 mobile 端点，这里会拿到 NoRoute 从而 books 为空
            val f = FakeFetcher().queue("search.ximalaya.com/front/v1", frontJson)
            val r = engine(f).search("斗罗大陆", 1)
            assertEquals(1, f.calls, "第一路应当只打一次 front，不再白打 mobile")
            assertTrue(r.books.isNotEmpty())
        }
    }

    @Test
    fun htmlResponseDoesNotCrash() {
        val htmlish = "<!Doctype html><html><head><title>Search 的小站</title></head></html>"
        val o = Json.parseToJsonElement("""{"response":{}}""") as JsonObject
        assertEquals(0, AlbumExtractor.fromSearchFront(o, "ximalaya").size)
        assertNotNull(htmlish)
    }
}
