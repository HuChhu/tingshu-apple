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

    /** 窗口起点：超过 cooldownMs 没请求过就重置计数（限流应该是「窗口内」的，不是永久的） */
    private var windowStart = 0L

    fun canAttempt(): Pair<Boolean, String> {
        if (blocked) return false to "网页搜索端点已拉黑（IP 级），需人工解除"
        // 窗口滚动：距上次请求超过 cooldown 就清零重来。
        // 之前 attempts 只增不减，3 次成功搜索后第 4 次起永久返回「已达上限」直到重启 App。
        if (windowStart > 0 && now() - windowStart >= cooldownMs) {
            attempts = 0
            windowStart = now()
            paused = false
            pauseReason = ""
        }
        if (attempts >= maxAttempts) return false to "已达到最多 " + maxAttempts + " 次上限"
        if (lastAt > 0) {
            val elapsed = now() - lastAt
            if (elapsed < cooldownMs) return false to "冷却中，还需等待 " + (cooldownMs - elapsed) / 1000 + " 秒"
        }
        return true to ""
    }

    fun record(riskLevel: Int?, reason: String, ok: Boolean) {
        lastAt = now()
        if (windowStart == 0L) windowStart = now()
        // 只有失败才计入上限：成功请求不应该消耗预算。
        // 原来「成功也 attempts++」导致正常用户搜 3 次就被锁死。
        if (!ok) attempts++
        else { attempts = 0; windowStart = now(); paused = false }
        lastRiskLevel = riskLevel
        if (!ok) { paused = true; pauseReason = reason.ifEmpty { "风控信号" } }
        if (!ok && attempts >= maxAttempts) {
            blocked = true; paused = true
            pauseReason = "网页搜索连续失败，达到上限，IP 级拉黑"
        }
    }
}
