package com.local.audiobook.core

import com.local.audiobook.core.engine.VodSource
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * provide/vod 协议源测试。
 *
 * JSON 样本用 base64 存放 —— 协议里用 $ 做分隔符，
 * 直接在 Kotlin 字符串里写会触发插值，base64 编码彻底绕开这个坑。
 */
@OptIn(ExperimentalEncodingApi::class)
class VodSourceTest {

    /** 真实响应（api.ffzyapi.com，2026-11-23 实测） */
    private val captured: String = String(Base64.decode("eyJjb2RlIjoxLCJtc2ciOiLmlbDmja7liJfooagiLCJwYWdlIjoiMSIsInBhZ2Vjb3VudCI6NDk2MiwidG90YWwiOjEwMCwibGlzdCI6W3sidm9kX2lkIjoxLCJ2b2RfbmFtZSI6IuW4g+WQiSIsInZvZF9waWMiOiJodHRwczovL2ltZy94LmpwZyIsInR5cGVfbmFtZSI6IuWJp+aDheeJhyIsInZvZF95ZWFyIjoiMjAyMSIsInZvZF9yZW1hcmtzIjoiSEQiLCJ2b2RfY29udGVudCI6IjxwPuWJp+aDheeugOS7izwvcD4iLCJ2b2RfcGxheV91cmwiOiJIROS4reWtl+eJiCRodHRwczovL3ZpcC5mZnp5LXBsYXkuY29tL3NoYXJlL2FiYy5tM3U4I0hE5Zu96K+t54mIJGh0dHBzOi8vdmlwLmZmenktcGxheS5jb20vc2hhcmUvZGVmLm0zdTgifV19"))
    private val allComplete: String = String(Base64.decode("eyJjb2RlIjoxLCJsaXN0IjpbeyJ2b2RfaWQiOjIsInZvZF9uYW1lIjoi5YWo6ZuG5YmnIiwidm9kX3JlbWFya3MiOiLlhagyNOmbhiIsInZvZF9wbGF5X3VybCI6IjEkaHR0cHM6Ly94LzEubTN1OCJ9XX0="))
    private val emptyListResp: String = String(Base64.decode("eyJjb2RlIjowLCJsaXN0IjpbXX0="))

    private fun mk(src: String = captured) = VodSource(
        baseUrl = "http://api.ffzyapi.com",
        fetcher = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) =
                FetchOutcome.Ok(200, src)
        },
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        sourceId = "ffzy",
        name = "FFZY",
    )

    @Test
    fun parsesRealResponse() {
        runBlocking {
            val r = mk().search("布吉", 1)
            assertEquals(1, r.books.size)
            val b = r.books.first()
            assertEquals("布吉", b.title)
            assertEquals(4962, r.maxPage)
            assertEquals("http://api.ffzyapi.com/vod/1", b.bookUrl)
            assertEquals(2L, b.trackCount, "播放串有 2 段，集数应为 2")
        }
    }

    @Test
    fun stripsHtmlFromIntro() {
        runBlocking {
            val b = mk().search("x", 1).books.first()
            assertTrue(!b.intro.contains("<p>"), "简介应去掉 HTML 标签：" + b.intro)
            assertTrue(b.intro.contains("剧情简介"))
        }
    }

    @Test
    fun parsesPlayUrlToEpisodes() {
        val sep = '\u0024'.toString()  // '$'
        val raw = "HD中字版" + sep + "https://vip.ffzy-play.com/share/abc.m3u8#HD国语版" + sep + "https://vip.ffzy-play.com/share/def.m3u8"
        val eps = mk().parsePlayUrl(raw, "1")
        assertEquals(2, eps.size)
        assertEquals("HD中字版", eps[0].title)
        assertEquals("https://vip.ffzy-play.com/share/abc.m3u8", eps[0].url)
        assertEquals(1, eps[0].index)
        assertEquals(2, eps[1].index)
    }

    @Test
    fun playUrlTakesFirstRouteOnly() {
        val d = '\u0024'.toString()
        val triple = d + d + d
        val raw = "EP1" + d + "https://a/1.m3u8#EP2" + d + "https://a/2.m3u8" + triple + "EP1" + d + "https://b/1.m3u8"
        val eps = mk().parsePlayUrl(raw, "9")
        assertEquals(2, eps.size, "应只取第一条线路")
        assertEquals("https://a/1.m3u8", eps[0].url)
    }

    @Test
    fun emptyPlayUrlGivesNoEpisodes() {
        assertEquals(0, mk().parsePlayUrl("", "1").size)
    }

    @Test
    fun detailReturnsBookAndEpisodes() {
        runBlocking {
            val d = mk().bookDetail("http://api.ffzyapi.com/vod/1", true, false)
            assertEquals("布吉", d.book.title)
            assertEquals(2, d.episodes.size)
            assertEquals("https://vip.ffzy-play.com/share/abc.m3u8", d.episodes[0].url)
        }
    }

    @Test
    fun extractorAcceptsM3u8Directly() {
        runBlocking {
            val a = mk().audioExtractor().extract("https://x.com/1.m3u8")
            assertEquals("https://x.com/1.m3u8", a.url)
        }
    }

    @Test
    fun marksFinishedWhenRemarksSayComplete() {
        runBlocking {
            val b = mk(allComplete).search("x", 1).books.first()
            assertEquals(true, b.isFinished, "备注含「全」应标完结")
        }
    }

    @Test
    fun emptyListGivesHint() {
        runBlocking {
            val r = mk(emptyListResp).search("不存在的片", 1)
            assertEquals(0, r.books.size)
            assertEquals("该源没有这本书", r.hint)
        }
    }
}
