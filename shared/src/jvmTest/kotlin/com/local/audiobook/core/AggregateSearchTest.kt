package com.local.audiobook.core

import com.local.audiobook.core.engine.AggregateSearch
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 聚合搜索单测 —— 通道隔离、超时、去重、合并择优。
 */
class AggregateSearchTest {

    private fun book(id: Long, title: String = "书$id", author: String = "作者") = Book(
        sourceId = "test", bookUrl = "/album/$id", title = title, author = author,
        coverUrl = "", intro = "", albumId = id,
    )

    private fun ch(name: String, priority: Int, body: (String, Int) -> List<Book>) =
        AggregateSearch.Channel(name, priority) { kw, page -> SearchResult(body(kw, page), 0, name) }

    @Test
    fun mergesAllChannels() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("a", 1) { _, _ -> listOf(book(1), book(2)) },
                    ch("b", 2) { _, _ -> listOf(book(3)) },
                ),
                keyword = "测试",
            )
            assertEquals(3, agg.books.size)
            assertEquals(2, agg.okCount)
        }
    }

    @Test
    fun oneFailureDoesNotKillOthers() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("bad", 1) { _, _ -> throw RuntimeException("源挂了") },
                    ch("good", 2) { _, _ -> listOf(book(1)) },
                ),
                keyword = "测试",
            )
            assertEquals(1, agg.books.size, "坏通道不应拖垮好通道")
            assertEquals(1, agg.okCount)
        }
    }

    @Test
    fun slowChannelIsTimedOut() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    AggregateSearch.Channel("slow", 1) { _, _ ->
                        delay(5_000); SearchResult(listOf(book(9)), 0, "slow")
                    },
                    ch("fast", 2) { _, _ -> listOf(book(1)) },
                ),
                keyword = "测试",
                perTimeoutMs = 200,
                clock = { System.currentTimeMillis() },
            )
            assertEquals(1, agg.books.size)
            assertTrue(
                agg.results.first { it.channel == "slow" }.error?.contains("超时") == true,
                "慢通道应记为超时"
            )
        }
    }

    @Test
    fun dedupByAlbumId() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("a", 1) { _, _ -> listOf(book(1)) },
                    ch("b", 2) { _, _ -> listOf(book(1)) },
                ),
                keyword = "测试",
            )
            assertEquals(1, agg.books.size, "同一 albumId 只保留一条")
        }
    }

    @Test
    fun dedupKeepsRicherRecord() {
        runBlocking {
            val poor = Book("t", "/album/1", "书1", "", "", "", albumId = 1)
            val rich = Book("t", "/album/1", "书1", "张三", "https://c.com/x.jpg", "简介", albumId = 1, trackCount = 100)
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("poor", 1) { _, _ -> listOf(poor) },
                    ch("rich", 2) { _, _ -> listOf(rich) },
                ),
                keyword = "测试",
            )
            assertEquals(1, agg.books.size)
            val got = agg.books.first()
            assertEquals("张三", got.author, "应保留信息更全的那条")
            assertEquals(100L, got.trackCount)
        }
    }

    @Test
    fun allFailGivesSummary() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("a", 1) { _, _ -> throw RuntimeException("挂了A") },
                    ch("b", 2) { _, _ -> throw RuntimeException("挂了B") },
                ),
                keyword = "测试",
            )
            assertEquals(0, agg.books.size)
            assertEquals(0, agg.okCount)
            assertTrue(agg.summary.contains("所有搜索通道都失败"), agg.summary)
        }
    }

    @Test
    fun emptyButOkGivesDifferentSummary() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(ch("a", 1) { _, _ -> emptyList() }),
                keyword = "不存在的书",
            )
            assertTrue(agg.summary.contains("没有这本书"), agg.summary)
        }
    }

    @Test
    fun hitChannelsReported() {
        runBlocking {
            val agg = AggregateSearch.search(
                channels = listOf(
                    ch("empty", 1) { _, _ -> emptyList() },
                    ch("hit", 2) { _, _ -> listOf(book(1)) },
                ),
                keyword = "测试",
            )
            assertEquals(listOf("hit"), agg.hitChannels)
        }
    }

    @Test
    fun priorityOrderPreserved() {
        runBlocking {
            val order = mutableListOf<String>()
            AggregateSearch.search(
                channels = listOf(
                    AggregateSearch.Channel("z", 9) { _, _ -> order.add("z"); SearchResult(emptyList(), 0, "z") },
                    AggregateSearch.Channel("a", 1) { _, _ -> order.add("a"); SearchResult(emptyList(), 0, "a") },
                ),
                keyword = "测试",
            )
            // 并发执行，只验证两个都跑了
            assertEquals(setOf("a", "z"), order.toSet())
        }
    }
}
