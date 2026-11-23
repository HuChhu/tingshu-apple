package com.local.audiobook.core

import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 全局限速器测试（P1 审计回归）。
 *
 * 钉死两条纪律：并发 1、请求之间有间隔。
 * 旧实现在 block() 结束时就把 mutex 放开，"在飞"标记从来没人看，
 * 慢请求会让后续请求插队 —— 这里的 slowBlocksAreNotOverlapped 就是那条的回归测试。
 */
class RequestThrottleTest {

    @Test
    fun slowBlocksAreNotOverlapped() = runBlocking {
        val now = AtomicInteger(0)
        val t = RequestThrottle(minIntervalMs = 0L, clock = { now.get().toLong() })
        val concurrent = AtomicInteger(0)
        val peak = AtomicInteger(0)
        val done = AtomicInteger(0)

        val jobs = (1..4).map {
            async<Unit> {
                t.run<Unit> {
                    val c = concurrent.incrementAndGet()
                    val seen = peak.get()
                    if (c > seen) peak.set(c)
                    delay(60)                    // 模拟一个慢请求
                    concurrent.decrementAndGet()
                    done.incrementAndGet()
                }
            }
        }
        jobs.awaitAll()

        assertEquals(4, done.get(), "4 个 block 都要跑完")
        assertEquals(1, peak.get(), "并发必须恒为 1，实测峰值 " + peak.get())
    }

    @Test
    fun requestsAreSpacedByMinInterval() = runBlocking {
        val t = RequestThrottle(minIntervalMs = 60L, clock = { System.nanoTime() / 1_000_000 })
        val stamps = mutableListOf<Long>()
        repeat(3) {
            t.run<Unit> { stamps.add(System.nanoTime() / 1_000_000) }
        }
        val gap1 = stamps[1] - stamps[0]
        val gap2 = stamps[2] - stamps[1]
        assertTrue(gap1 >= 55, "第 1→2 次间隔应 >=55ms，实测 " + gap1)
        assertTrue(gap2 >= 55, "第 2→3 次间隔应 >=55ms，实测 " + gap2)
        assertEquals(3L, t.totalRequests)
    }

    @Test
    fun failedBlockStillReleasesGate() = runBlocking {
        val t = RequestThrottle(minIntervalMs = 0L, clock = { 0L })
        runCatching { t.run<Unit> { throw IllegalStateException("boom") } }
        // 闸门没释放的话这里会永远卡住（用 isBusy 直接断言）
        assertTrue(!t.isBusy, "异常路径必须释放闸门")
        val v = t.run<Int> { 42 }
        assertEquals(42, v, "异常之后还能继续用")
    }
}
