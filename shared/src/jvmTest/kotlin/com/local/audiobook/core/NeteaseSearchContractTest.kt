package com.local.audiobook.core

import com.local.audiobook.core.engine.NeteaseSource
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 网易云搜索契约（R4 新增）。
 * 背景：官方搜索接口的 album 对象**没有 picUrl**，之前拼 CDN 全是 404；
 * 封面必须靠 song/detail 批量补。这条链路没有测试，改坏两次都没拦住。
 */
class NeteaseSearchContractTest {

    /** 真实搜索响应裁剪（2026-11-24 抓，字段名原样） */
    private val searchJson = """
    {"result":{"songs":[
      {"id":37049621,"name":"斗罗大陆","artists":[{"id":1,"name":"某某"}],
       "album":{"id":33010,"name":"专辑A","picId":109951165748385000}},
      {"id":1431292823,"name":"守拙归田园","artists":[{"id":2,"name":"水先遊"}],
       "album":{"id":281995036,"name":"水先游","picId":0}}
    ],"songCount":2}}
    """.trimIndent()

    /** song/detail 才带真实 picUrl */
    private val detailJson = """
    {"songs":[
      {"id":37049621,"album":{"id":33010,"picUrl":"https://p1.music.126.net/AAA==/109951165748385000.jpg"}},
      {"id":1431292823,"album":{"id":281995036,"picUrl":"https://p2.music.126.net/BBB==/109951160000000000.jpg"}}
    ]}
    """.trimIndent()

    private class Route(private val map: Map<String, String>) : JsonFetcher {
        override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome {
            for ((k, v) in map) if (url.contains(k)) return FetchOutcome.Ok(200, v)
            return FetchOutcome.Failed("NoRoute", url)
        }
    }

    private fun src(f: JsonFetcher) = NeteaseSource(
        fetcher = f,
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
    )

    @Test
    fun searchParsesOfficialShape() = runBlocking {
        val f = Route(mapOf("song/detail" to detailJson, "search/get" to searchJson))
        val r = src(f).search("斗罗大陆", 1)
        assertEquals(2, r.books.size)
        assertEquals("斗罗大陆", r.books[0].title)
        assertEquals("某某", r.books[0].author, "artists[0].name 才是作者")
        assertEquals(37049621L, r.books[0].albumId)
    }

    @Test
    fun coversComeFromSongDetailNotGuesswork() = runBlocking {
        val f = Route(mapOf("song/detail" to detailJson, "search/get" to searchJson))
        val r = src(f).search("斗罗大陆", 1)
        // 关键：封面必须来自 song/detail 的 album.picUrl，
        // 不能是 meting type=pic（那条实测 5/5 全 404）
        assertTrue(r.books[0].coverUrl.startsWith("https://p1.music.126.net/"),
            "封面应来自 song/detail，实际=" + r.books[0].coverUrl)
        assertTrue(r.books[1].coverUrl.startsWith("https://p2.music.126.net/"))
        assertTrue(!r.books[0].coverUrl.contains("meting"), "不能用 meting pic 端点")
    }

    @Test
    fun coverFailureDoesNotBreakSearch() = runBlocking {
        // song/detail 挂掉时，搜索本身仍然要能用（封面空着）
        val f = Route(mapOf("search/get" to searchJson))
        val r = src(f).search("斗罗大陆", 1)
        assertEquals(2, r.books.size, "封面失败不应影响搜索结果")
    }

    @Test
    fun emptyResultReportsHint() = runBlocking {
        val f = Route(mapOf("search/get" to """{"result":{"songs":[]}}"""))
        val r = src(f).search("不存在的书", 1)
        assertTrue(r.books.isEmpty())
        assertTrue(!r.hint.isNullOrEmpty(), "空结果要给 hint")
    }
}
