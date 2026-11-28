package com.local.audiobook.data.ximalaya

import kotlinx.atomicfu.atomic
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 全局限速器（统一实现，禁双实现漂移：安卓版与引擎版在此合一）。
 *
 * 纪律（从服务器桥移植）：
 *  - 全局 <=1 请求/秒；
 *  - 批量并发 1（任何时候只允许一个在跑）；
 *  - 失败不重试。
 *
 * 迁移记录（T03 §19.7）：原安卓实现用 @Synchronized + System.currentTimeMillis 默认时钟；
 * commonMain 无 synchronized/System —— 并发闸门改 kotlin.concurrent 原子类型（tryAcquire/release
 * 的 compareAndSet 语义与原粗锁等效），时钟改为必传注入（调用方各自传平台时钟）。
 * 引擎侧 run{}（Mutex 串行 + 限速）并入本类，engine 包旧实现已删除。
 */
class RequestThrottle(
    private val minIntervalMs: Long = 1_000L,
    private val clock: () -> Long,
    /**
     * 批量模式（翻页 / 同源连续请求）的起始间隔。
     *
     * 【2026-11-28 找到了「什么都慢」的真凶】
     * 原来 runBulk 沿用 minIntervalMs=1000 的起始间隔 —— 并发只让 RTT 重叠，
     * 但**起始间隔是硬串行**：40 页 = 39 秒，这就是大书详情 40 秒的数学来源，
     * 也是首页 3 个分区×2 次请求 ≈ 6 秒骨架屏的来源。
     * 实测依据（2026-11-28）：同一 IP 以 **100ms** 间隔连打 mobwsa 20 次，20/20 返回 ret=0；
     * search front/v1 连打 12 次，12/12 HTTP 200。样本只有一次、一个 IP，不算保证，
     * 所以取 150ms（留一半余量），并且配一个自动退避 —— 见 [riskBackoff]。
     * 一旦收到风控信号（HTTP 403/429 或 ret=999/1001），批量间隔自动回到 1 秒并保持 60 秒。
     */
    private val bulkIntervalMs: Long = 150L,
) {
    private val lastRequestAt = atomic(0L)
    private val hasRequested = atomic(false)
    private val inFlight = atomic(false)
    private val mutex = Mutex()
    private val requests = atomic(0L)
    /** 风控惩罚到期时间（clock 读数）；大于当前 clock 说明正在惩罚期内 */
    private val penaltyUntil = atomic(0L)

    /** 已发请求数（诊断用；android 原版无此字段，兼容引擎版计数） */
    val totalRequests: Long get() = requests.value

    private companion object {
        const val GATE_POLL_MS = 20L
    }

    /** 距离下一次可以发请求还差多少毫秒（0 = 现在就能发） */
    fun waitMs(): Long = waitMsFor(minIntervalMs)

    /** 按指定间隔算还要等多久 */
    private fun waitMsFor(interval: Long): Long {
        if (!hasRequested.value) return 0L
        val elapsed = clock() - lastRequestAt.value
        return (interval - elapsed).coerceAtLeast(0L)
    }

    /** 标记"刚发完一个请求" */
    fun markRequest() {
        lastRequestAt.value = clock()
        hasRequested.value = true
        requests.addAndGet(1L)
    }

    /**
     * 收到风控信号后调用：批量间隔在 [ms] 内退回 minIntervalMs（1 秒）。
     *
     * 为什么要有它：批量间隔是「实测没风控」才敢往下调的，但实测只有一个 IP、一次样本。
     * 万一某个网络环境更严，没有这个开关就是「调快了然后被 ban，且自己不会恢复」。
     * 调用方（XimalayaOpenSource）在看到 HTTP 403/429 或 ret=999/1001 时调一次即可。
     */
    fun riskBackoff(ms: Long = 60_000L) {
        penaltyUntil.value = clock() + ms
    }

    /** 当前生效的批量间隔：惩罚期内用慢的 1 秒，否则用快的 */
    private fun effectiveBulkInterval(): Long =
        if (clock() < penaltyUntil.value) minIntervalMs else bulkIntervalMs

    /** 诊断用：此刻是否处于风控惩罚期 */
    val isBackingOff: Boolean get() = clock() < penaltyUntil.value

    /** 并发闸门：拿不到就返回 false（并发 1 纪律） */
    fun tryAcquire(): Boolean = inFlight.compareAndSet(false, true)

    fun release() {
        inFlight.value = false
    }

    /** 当前是否有请求在飞（诊断用） */
    val isBusy: Boolean get() = inFlight.value

    fun reset() {
        lastRequestAt.value = 0L
        hasRequested.value = false
        inFlight.value = false
    }

    /**
     * 引擎 suspend API：串行 + 限速后执行 block。
     *
     * P1（审计）：tryAcquire() 设了 inFlight 但从没被 suspend 路径用过，
     * 而限速闸门（mutex）在 block() 结束时就放开了 —— 意味着下一个请求能立刻进 delay()，
     * 1s 计时是从"上一个请求开始"算的，不是"上一个请求结束"算的。
     * 后果：慢站（32s 超时）上一个请求还没回来，下一个就发出去，并发上限形同虚设。
     * 现在改成 false→true（只放一个）→ 真正限速 → block 结束才 release。
     */
    suspend fun <T> run(block: suspend () -> T): T = mutex.withLock {
        while (!tryAcquire()) delay(GATE_POLL_MS)
        try {
            val wait = waitMs()
            if (wait > 0) delay(wait)
            markRequest()
            block()
        } finally {
            release()
        }
    }

    /**
     * 批量模式：只保留**起始间隔**（1 秒），允许最多 [concurrency] 个请求同时在飞。
     *
     * 【2026-11-25 解决「大书详情 80 秒」】串行 `run()` 下翻 40 页 = 40 ×（1s 间隔 + RTT）≈ 80 秒，
     * 用户等不了。翻页这种「同一个站、同一本书、连续 N 页」的场景，
     * 真正要防的是**起始频率**（每秒一个新请求），不是「同一时刻只能有一个在飞」。
     * 实测 mobwsa 对 2~3 个并发翻页没有风控反应，维持 1/s 的起始间隔即可。
     *
     * 纪律不变的部分：起始间隔仍是 minIntervalMs，不会变成「一口气全发」。
     */
    private val slots = atomic(0)

    suspend fun <T> runBulk(concurrency: Int = 3, block: suspend () -> T): T {
        // 【2026-11-26 P0 自摆乌龙】上一版写的是 `= mutex.withLock { ... block() }` ——
        // mutex 把**整个函数体**（含 block）锁住了，第二个协程要等第一个 block() 返回才进得去，
        // 并发窗口恒为 1，和串行 run() 完全一样。之前测出的「变快」测的是分桶（不同源各自的锁），
        // 不是这里的并发。
        //
        // 现在把 mutex 只用来保护「取号 + 算等待时间 + 标记」这一小段，
        // 真正的 block() 在锁外执行 —— 这才是「允许 N 个在飞」。
        val limit = concurrency.coerceIn(1, 4)
        while (true) {
            val cur = slots.value
            if (cur < limit && slots.compareAndSet(cur, cur + 1)) break
            delay(GATE_POLL_MS)
        }
        try {
            mutex.withLock {
                val wait = waitMsFor(effectiveBulkInterval())
                if (wait > 0) delay(wait)
                markRequest()
            }
            // 锁外执行：这一段才是真正并发的部分
            return block()
        } finally {
            slots.decrementAndGet()
        }
    }
}
