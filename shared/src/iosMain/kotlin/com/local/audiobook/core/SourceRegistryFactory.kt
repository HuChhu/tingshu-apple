package com.local.audiobook.core

import com.local.audiobook.core.net.IosJsonFetcher
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.engine.darwin.Darwin

/**
 * 给 Swift 用的 SourceRegistry 工厂。
 *
 * 【为什么需要】壳的白名单禁止 import Ktor（见 check-whitelist.sh），
 * 所以 HttpClient / Darwin 必须在 Kotlin 侧构好再传出去。
 * Swift 侧只需要：SharedBridge.allSources() / search(...)，不碰 Ktor。
 */
object SourceRegistryFactory {

    /**
     * 由壳注入的真实登录态。
     *
     * 关键修复（装机反馈 2026-11-23）：
     * 之前这里写死返回 null —— 不管用户在设置页登没登录，
     * 引擎永远拿不到 Cookie，登录版永远报「需要登录」。
     * 现在改成可变实现：壳在启动和登录成功后调用 setCookie(...)，
     * 把 CookieStore 里的真实 Cookie 灌进来。
     */
    private var injectedCookie: String? = null

    var cookieProvider: CookieProvider = object : CookieProvider {
        override suspend fun cookie(): String? = injectedCookie
        override suspend fun refresh() {}
    }

    /** 壳调用：把 HTTPCookieStorage 里的喜马拉雅 Cookie 串灌进引擎 */
    fun setCookie(cookie: String?) {
        injectedCookie = cookie
    }

    /** 供壳查询当前注入状态（排障用） */
    fun currentCookieLength(): Int = injectedCookie?.length ?: 0

    private val singleton: SourceRegistry by lazy {
        SourceRegistry(
            fetcher = IosJsonFetcher(
                HttpClient(Darwin) {
                    // Swift 席 P0-2：默认 60s 会把半死站点卡死在「解析地址…」。
                    // 实测席补充：aj006 播放页要 29.8s 才拉完（247KB 慢站），
                    // 20s 会把本来能播的源判死。
                    // 折中：连接 12s（连不上就是连不上），
                    //       请求 32s（够慢站拉完，又不至于让用户干等一分钟）。
                    install(HttpTimeout) {
                        requestTimeoutMillis = 45_000
                        connectTimeoutMillis = 12_000
                        socketTimeoutMillis = 45_000
                    }
                }
            ),
            nowMs = { PlatformClock.nowMs() },
            cookieProvider = cookieProvider,
        )
    }

    /** 全局单例（共用连接池） */
    fun registry(): SourceRegistry = singleton
}
