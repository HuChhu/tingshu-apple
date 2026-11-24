package com.local.audiobook.core

import com.local.audiobook.core.engine.TemplateTingSite
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 多锚点同名书的标题合并回归（29/32 个模板站都是这种结构）。
 * 背景：封面锚点没有 title 属性、正文是评分「0.0」，标题锚点才带真书名。
 * 早期实现「先到先得」，导致 ting954 全站书名变成 0.0。
 */
class BookTitleMergeTest {

    private class NoFetch : JsonFetcher {
        override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome =
            FetchOutcome.Failed("NoRoute", url)
    }

    private fun site() = TemplateTingSite(
        fetcher = NoFetch(),
        throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        sourceId = "test",
        base = "https://example.com",
        siteName = "test",
        bookHrefPattern = "/(\\d+)\\.html",
    )

    @Test
    fun coverAnchorWithScoreDoesNotWin() {
        val html = """<a href="/1.html"><img src="/c1.jpg"><span class="score">0.0</span></a>
<a class="t" href="/1.html" title="道士不好惹">道士不好惹</a>"""
        val books = site().parseBookList(html)
        assertEquals(1, books.size, "同一本书只应出现一次")
        assertEquals("道士不好惹", books[0].title, "不能被封面的评分 0.0 占位")
    }

    @Test
    fun coverMergedWhenTitleComesLater() {
        val html = """<a href="/2.html"><img src="/c2.jpg"><span class="score">9.8</span></a>
<a class="t" href="/2.html" title="重生之我在异界">重生之我在异界</a>"""
        val b = site().parseBookList(html).single()
        assertEquals("重生之我在异界", b.title)
        assertTrue(b.coverUrl.endsWith("c2.jpg"), "封面不能被丢：第二次命中也应合并封面")
    }

    @Test
    fun attrTitleBeatsBodyTitle() {
        val html = """<a href="/3.html" title="正式书名">正文杂字</a>"""
        assertEquals("正式书名", site().parseBookList(html).single().title)
    }

    @Test
    fun scoreLikeTitlesNeverBecomeBookName() {
        // 实测过的 9 种旧标题里，这几种都是"像评分/像数字"，不能被当成书名
        for (t in listOf("0.0", "9.8", "1.2万", "0")) {
            val html = """<a href="/5.html">$t</a>"""
            assertTrue(site().parseBookList(html).isEmpty(), "「$t」不该被当成书名")
        }
    }

    @Test
    fun threeAnchors_buttonTextDoesNotOverwrite() {
        // 真实页面结构：封面锚点 → 书名锚点 → 「开始收听」按钮锚点。
        // R2 时期第三段的按钮文字和真书名同分（都是 4 字含中文），
        // 后到的 body 覆盖了先到的真书名 —— 8 个站整站中招。
        val html = """<a href="/9.html"><img src="/c9.jpg"><span>9.8</span></a>
<a class="t" href="/9.html" title="守拙归田园">守拙归田园</a>
<a class="play" href="/9.html">开始收听</a>"""
        val books = site().parseBookList(html)
        assertEquals(1, books.size)
        assertEquals("守拙归田园", books.single().title, "按钮文字不能覆盖真书名")
    }

    @Test
    fun genericUiWordsNeverBecomeTitle() {
        for (w in listOf("开始收听", "立即收听", "播放", "下载", "详情", "更多", "继续播放")) {
            val html = """<a href="/7.html">$w</a>"""
            assertTrue(site().parseBookList(html).isEmpty(), "「$w」是通用 UI 词，不能当书名")
        }
    }

    @Test
    fun paragraphTextRejected() {
        val html = """<a href="/4.html">这是一段很长的简介，有逗号。也有句号，明显不是书名，应被丢弃。</a>"""
        assertTrue(site().parseBookList(html).isEmpty(), "句读密集的正文不能被当成书名")
    }
}
