package com.local.audiobook.core.engine

// 对拍基准：bridge risk.py 网页搜索止损（≤3 次、≥30s 冷却、达限拉黑、失败即暂停）
// spike 为内存态；落盘持久化与人工恢复入口在 M2+ 补齐
class WebSearchBudget(private val maxAttempts: Int = 3, private val cooldownMs: Long = 30_000, private val now: () -> Long) {
    var attempts = 0; private set
    var lastAt = 0L; private set
    var blocked = false; private set
    var paused = false; private set
    var pauseReason = ""; private set
    var lastRiskLevel: Int? = null; private set

    /** @deprecated 只为兼容旧测试保留；真正的窗口起点是 lastFailAt */
    private var windowStart = 0L

    fun canAttempt(): Pair<Boolean, String> {
        if (blocked) return false to "网页搜索端点已拉黑（IP 级），需人工解除"
        // 窗口滚动：距**上次失败**超过 cooldown 就清零重来。
        // 旧实现用 lastAt（任何请求）做窗口起点，且拴在 canAttempt 里修改状态：
        // 它会在 record() 之后把 attempts 清零 → 失败不累计 → 连续风控永远触不到 3 次上限（拉黑失效）；
        // 同时它在一次请求内被调用两次 → 第二次就把计数清了。
        // 现在拆开：状态变更只在 record()，canAttempt() 是纯查询。
        rollWindowIfDue()
        if (attempts >= maxAttempts) return false to "已达到最多 " + maxAttempts + " 次上限"
        if (lastAt > 0) {
            val elapsed = now() - lastAt
            if (elapsed < cooldownMs) return false to "冷却中，还需等待 " + (cooldownMs - elapsed) / 1000 + " 秒"
        }
        return true to ""
    }

    /** 窗口滚动（只分析失败计数），由 record() 与 canAttempt() 共用，只清失败计数 */
    private fun rollWindowIfDue() {
        val lastFail = lastFailAt
        // 从未失败过就不涉及窗口；有失败且超过冷却 → 清零
        if (lastFail > 0L && now() - lastFail >= cooldownMs && attempts > 0) {
            attempts = 0
            paused = false
            pauseReason = ""
        }
    }

    /** 上次失败时刻（窗口起点）；0 = 从未失败 */
    var lastFailAt = 0L; private set

    fun record(riskLevel: Int?, reason: String, ok: Boolean) {
        lastAt = now()
        rollWindowIfDue()
        // 只有失败才计入上限：成功请求不应该消耗预算。
        // 原来「成功也 attempts++」导致正常用户搜 3 次就被锁死。
        if (!ok) { attempts++; lastFailAt = now() }
        else { attempts = 0; lastFailAt = 0L; paused = false }
        lastRiskLevel = riskLevel
        if (!ok) { paused = true; pauseReason = reason.ifEmpty { "风控信号" } }
        if (!ok && attempts >= maxAttempts) {
            blocked = true; paused = true
            pauseReason = "网页搜索连续失败，达到上限，IP 级拉黑"
        }
    }
}
