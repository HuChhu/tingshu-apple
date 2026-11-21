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

    fun canAttempt(): Pair<Boolean, String> {
        if (blocked) return false to "网页搜索端点已拉黑（IP 级），需人工解除"
        if (attempts >= maxAttempts) return false to "已达到最多 " + maxAttempts + " 次上限"
        if (lastAt > 0) {
            val elapsed = now() - lastAt
            if (elapsed < cooldownMs) return false to "冷却中，还需等待 " + (cooldownMs - elapsed) / 1000 + " 秒"
        }
        return true to ""
    }

    fun record(riskLevel: Int?, reason: String, ok: Boolean) {
        attempts++
        lastAt = now()
        lastRiskLevel = riskLevel
        if (!ok) { paused = true; pauseReason = reason.ifEmpty { "风控信号" } }
        if (!ok && attempts >= maxAttempts) {
            blocked = true; paused = true
            pauseReason = "网页搜索连续失败，达到上限，IP 级拉黑"
        }
    }
}
