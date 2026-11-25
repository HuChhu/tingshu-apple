package com.local.audiobook.core

import com.local.audiobook.core.engine.WebSearchBudget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 搜索预算窗口（v1.4.9 审计）。
 *
 * 旧实现两个坑：
 *   ① canAttempt() 里修改状态，且用 lastAt（任何请求）做窗口起点
 *     → record() 之后再调 canAttempt() 就把 attempts 清零，连续失败永远拉黑不了
 *   ② 超过冷却就清零 → 失败也被当成“新开始”，与“成功不消耗预算”的意图冲突
 */
class WebSearchBudgetTest {

    private var clock = 1_000_000L
    private fun budget() = WebSearchBudget(maxAttempts = 3, cooldownMs = 30_000, now = { clock })

    @Test
    fun successDoesNotConsumeBudget() {
        val b = budget()
        repeat(10) {
            clock += 31_000
            assertTrue(b.canAttempt().first)
            b.record(null, "", true)
        }
        assertEquals(0, b.attempts, "成功不应消耗预算")
        assertFalse(b.blocked)
    }

    @Test
    fun consecutiveFailuresStillReachBlock() {
        val b = budget()
        // 每次请求前都 canAttempt（模拟真实调用序），中间隔 1s（不足冷却 30s）
        repeat(3) {
            clock += 1_000
            b.canAttempt()
        }
        clock += 1_000
        b.record(5, "风控", false)
        clock += 1_000
        b.record(5, "风控", false)
        clock += 1_000
        b.record(5, "风控", false)
        assertEquals(3, b.attempts, "三次连续失败应计满")
        assertTrue(b.blocked, "达到 3 次上限必须拉黑")
    }

    @Test
    fun windowResetsOnlyAfterCooldownFromLastFailure() {
        val b = budget()
        clock += 1_000; b.record(null, "", false)
        clock += 1_000; b.record(null, "", false)
        assertEquals(2, b.attempts)
        // 冷却 未过 → 不清零
        clock += 5_000
        b.canAttempt()
        assertEquals(2, b.attempts, "冷却未过不应清零")
        // 冷却 已过 → canAttempt 本身仍然不改状态（纯查询），但应该放行
        clock += 30_000
        assertTrue(b.canAttempt().first, "冷却过后应放行")
        assertEquals(2, b.attempts, "canAttempt 是纯查询，不清零")
        // 真正的清零发生在 record() 里
        b.record(null, "", true)
        assertEquals(0, b.attempts, "record 之后窗口滚动，计数归零")
    }

    @Test
    fun successResetsFailureCounter() {
        val b = budget()
        clock += 1_000; b.record(null, "", false)
        clock += 1_000; b.record(null, "", false)
        assertEquals(2, b.attempts)
        clock += 1_000; b.record(null, "", true)
        assertEquals(0, b.attempts, "一次成功就把连续失败清零")
        assertFalse(b.paused)
    }

    @Test
    fun canAttemptIsPureQuery() {
        val b = budget()
        clock += 1_000; b.record(null, "", false)
        clock += 1_000; b.record(null, "", false)
        // 连调三次 canAttempt，不该改变计数
        repeat(3) { b.canAttempt() }
        assertEquals(2, b.attempts, "canAttempt 不能有副作用")
    }

    @Test
    fun canAttemptHasNoSideEffectAcrossCooldown() {
        val b = budget()
        clock += 1_000; b.record(null, "", false)
        clock += 1_000; b.record(null, "", false)
        clock += 1_000; b.record(null, "", false)
        // 连续 3 次失败 → 拉黑
        assertTrue(b.blocked)
        assertFalse(b.canAttempt().first)
        val b2 = budget()
        clock += 1_000; b2.record(null, "", false)
        clock += 1_000; b2.record(null, "", false)
        // 跨过冷却窗口后再问：不改状态，但应放行
        clock += 40_000
        assertTrue(b2.canAttempt().first, "跨窗口后应放行")
        assertEquals(2, b2.attempts, "跨窗口查询不能改计数")
        assertTrue(b2.paused, "跨窗口查询不能清 paused")
    }
}
