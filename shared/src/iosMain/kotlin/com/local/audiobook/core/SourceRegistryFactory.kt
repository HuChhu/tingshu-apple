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

    private val singleton: SourceRegistry by lazy {
        SourceRegistry(
            fetcher = IosJsonFetcher(
                HttpClient(Darwin) {
                    // 60 秒默认超时会把半死站点的 UI 卡死在「解析地址…」。
                    // 15s 连接 + 20s 请求是听书场景的合理上限（Swift 席 P0-2）。
                    install(HttpTimeout) {
                        requestTimeoutMillis = 20_000
                        connectTimeoutMillis = 15_000
                    }
                }
            ),
            nowMs = { PlatformClock.nowMs() },
        )
    }

    /** 全局单例（共用连接池） */
    fun registry(): SourceRegistry = singleton
}
