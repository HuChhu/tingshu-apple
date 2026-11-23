package com.local.audiobook.core.net

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*

// JVM 形态：Ktor CIO。commonMain 引擎 + 引擎注入 = actual 触点 0（契约 C3）
class KtorJsonFetcher(private val client: HttpClient) : JsonFetcher {
    override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome = try {
        val resp = client.get(url) { headers.forEach { (k, v) -> header(k, v) } }
        FetchOutcome.Ok(resp.status.value, resp.bodyAsText())
    } catch (e: Exception) {
        FetchOutcome.Failed(e.javaClass.simpleName, e.message ?: "")
    }

    override suspend fun post(url: String, headers: Map<String, String>, form: Map<String, String>): FetchOutcome = try {
        val body = form.entries.joinToString("&") { (k, v) ->
            java.net.URLEncoder.encode(k, "UTF-8") + "=" + java.net.URLEncoder.encode(v, "UTF-8")
        }
        val resp = client.post(url) {
            headers.forEach { (k, v) -> header(k, v) }
            contentType(ContentType.Application.FormUrlEncoded)
            setBody(body)
        }
        FetchOutcome.Ok(resp.status.value, resp.bodyAsText())
    } catch (e: Exception) {
        FetchOutcome.Failed(e.javaClass.simpleName, e.message ?: "")
    }
}
