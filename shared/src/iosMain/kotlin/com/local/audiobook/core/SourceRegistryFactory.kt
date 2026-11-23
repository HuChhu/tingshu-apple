package com.local.audiobook.core

import com.local.audiobook.core.net.IosJsonFetcher
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin

/**
 * 给 Swift 用的 SourceRegistry 工厂。
 *
 * 【为什么需要】壳的白名单禁止 import Ktor（见 check-whitelist.sh），
 * 所以 HttpClient / Darwin 必须在 Kotlin 侧构好再传出去。
 * Swift 侧只需要：SharedBridge.allSources() / search(...)，不碰 Ktor。
 */
object SourceRegistryFactory {

    private val instance: SourceRegistry by lazy {
        SourceRegistry(
            fetcher = IosJsonFetcher(HttpClient(Darwin)),
            nowMs = { PlatformClock.nowMs() },
        )
    }

    /** 全局单例（共用连接池） */
    fun shared(): SourceRegistry = instance
}
