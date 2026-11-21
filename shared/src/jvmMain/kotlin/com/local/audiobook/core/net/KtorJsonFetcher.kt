package com.local.audiobook.core.net

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*

// JVM 形态：Ktor CIO。commonMain 引擎 + 引擎注入 = actual 触点 0（契约 C3）
class KtorJsonFetcher(private val client: HttpClient) : JsonFetcher {
    override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome = try {
        val resp = client.get(url) { headers.forEach { (k, v) -> header(k, v) } }
        FetchOutcome.Ok(resp.status.value, resp.bodyAsText())
    } catch (e: Exception) {
        FetchOutcome.Failed(e.javaClass.simpleName, e.message ?: "")
    }
}
