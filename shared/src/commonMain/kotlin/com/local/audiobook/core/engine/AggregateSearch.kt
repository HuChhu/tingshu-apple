package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import com.local.audiobook.core.SearchResult
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

/**
 * ============================================================
 *  聚合搜索（Aggregate Search）
 * ============================================================
 *
 * 【设计来源】参考「我的听书」的 AggregateSearchActivity：
 *   多个源并发搜索，单个源失败不影响其他源，最后合并去重。
 *   本项目为独立实现，只借鉴「并发 + 隔离 + 合并」这一结构，零代码复用。
 *
 * 【为什么需要】
 *   单源搜索有两个问题：
 *     ① 该源被风控拦住 → 整个搜索失败
 *     ② 该源没有这本书 → 用户以为没有
 *   多源并发后，任一源命中就有结果，成功率显著提升。
 *
 * 【纪律】
 *   ① 每个通道独立超时，慢的不拖累快的
 *   ② 任一通道抛异常只记录，不影响其他
 *   ③ 结果按 bookUrl 去重（同一本书多个源命中只留一条）
 *   ④ 全部失败才返回空 + 汇总的失败原因
 *   ⑤ 不因某个通道慢而取消已完成的通道
 */
object AggregateSearch {

    /** 一个搜索通道：名字 + 执行体 */
    class Channel(
        val name: String,
        val priority: Int,
        val run: suspend (keyword: String, page: Int) -> SearchResult?,
    )

    /** 单个通道的执行结果 */
    data class ChannelResult(
        val channel: String,
        val books: List<Book>,
        val ms: Long,
        val error: String? = null,
    )

    /** 聚合结果 */
    data class Aggregated(
        val books: List<Book>,
        val results: List<ChannelResult>,
        val totalMs: Long,
    ) {
        /** 成功的通道数 */
        val okCount: Int get() = results.count { it.error == null }

        /** 有书的通道 */
        val hitChannels: List<String> get() = results.filter { it.books.isNotEmpty() }.map { it.channel }

        /** 全部失败时的提示（给 UI 直接用） */
        val summary: String
            get() = when {
                books.isNotEmpty() -> ""
                okCount == 0 -> "所有搜索通道都失败了：" + results.joinToString("；") { "${it.channel}=${it.error}" }
                else -> "搜索通道都正常，但没有这本书"
            }
    }

    /**
     * 并发执行所有通道。
     *
     * @param channels     通道列表（按 priority 升序执行）
     * @param keyword      关键词
     * @param page         页码
     * @param perTimeoutMs 单通道超时（默认 12 秒，比单源的 30 秒短）
     */
    suspend fun search(
        channels: List<Channel>,
        keyword: String,
        page: Int = 1,
        perTimeoutMs: Long = 12_000L,
        clock: () -> Long = { 0L },
    ): Aggregated = coroutineScope {
        val started = clock()

        val jobs = channels.sortedBy { it.priority }.map { ch ->
            async {
                val t0 = clock()
                val outcome = withTimeoutOrNull(perTimeoutMs) {
                    runCatching { ch.run(keyword, page) }
                }
                val elapsed = clock() - t0
                when {
                    outcome == null -> ChannelResult(ch.name, emptyList(), elapsed, "超时 ${perTimeoutMs}ms")
                    else -> outcome.fold(
                        onSuccess = { r ->
                            ChannelResult(ch.name, r?.books ?: emptyList(), elapsed, r?.hint)
                        },
                        onFailure = { e ->
                            ChannelResult(ch.name, emptyList(), elapsed, e.message ?: e::class.simpleName ?: "未知错误")
                        },
                    )
                }
            }
        }

        val results = jobs.awaitAll()
        val merged = mergeDedup(results)

        Aggregated(merged, results, clock() - started)
    }

    /**
     * 合并去重。
     *
     * 去重键：albumId > 0 时用 albumId，否则用 bookUrl。
     * 优先保留信息更全的那条（标题/作者/封面/集数都不为空）。
     */
    fun mergeDedup(results: List<ChannelResult>): List<Book> {
        val byKey = LinkedHashMap<String, Book>()
        for (r in results) {
            for (b in r.books) {
                // P1-7：跨源 albumId 可能相同（不同站的 ID 空间独立），
                // 只用 albumId 去重会把喜马拉雅 123 和酷我 123 误合并。
                // 加 sourceId 前缀，确保同书只在同源内去重。
                val key = if (b.albumId > 0) "${b.sourceId}:album:${b.albumId}" else "${b.sourceId}:url:${b.bookUrl}"
                val existing = byKey[key]
                byKey[key] = if (existing == null) b else richer(existing, b)
            }
        }
        return byKey.values.toList()
    }

    /** 两本同书取信息更全的 */
    private fun richer(a: Book, b: Book): Book {
        fun score(x: Book): Int =
            (if (x.title.isNotBlank()) 1 else 0) +
            (if (x.author.isNotBlank()) 1 else 0) +
            (if (x.coverUrl.isNotBlank()) 1 else 0) +
            (if (x.trackCount > 0) 1 else 0) +
            (if (x.playCount > 0) 1 else 0) +
            (if (x.intro.isNotBlank()) 1 else 0)
        return if (score(b) > score(a)) b else a
    }
}
