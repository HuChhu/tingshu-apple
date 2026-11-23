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
) {
    private val lastRequestAt = atomic(0L)
    private val hasRequested = atomic(false)
    private val inFlight = atomic(false)
    private val mutex = Mutex()
    private val requests = atomic(0L)

    /** 已发请求数（诊断用；android 原版无此字段，兼容引擎版计数） */
    val totalRequests: Long get() = requests.value

    private companion object {
        const val GATE_POLL_MS = 20L
    }

    /** 距离下一次可以发请求还差多少毫秒（0 = 现在就能发） */
    fun waitMs(): Long {
        if (!hasRequested.value) return 0L
        val elapsed = clock() - lastRequestAt.value
        return (minIntervalMs - elapsed).coerceAtLeast(0L)
    }

    /** 标记"刚发完一个请求" */
    fun markRequest() {
        lastRequestAt.value = clock()
        hasRequested.value = true
        requests.addAndGet(1L)
    }

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
}
