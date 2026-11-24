package com.local.audiobook.core.net

import io.ktor.client.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*

/**
 * iOS 形态：Ktor Darwin 引擎（NSURLSession 后端）。
 * 与 jvmMain 的 KtorJsonFetcher 同语义：一次 GET、异常转 Failed，不重试、不硬冲。
 */
class IosJsonFetcher(private val client: HttpClient) : JsonFetcher {
    override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome = try {
        val resp = client.get(url) { headers.forEach { (k, v) -> header(k, v) } }
        if (resp.status.value in 200..299) {
            FetchOutcome.Ok(resp.status.value, resp.bodyAsText())
        } else {
            FetchOutcome.Failed("HTTP", "status=" + resp.status.value + " url=" + url.take(80))
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e   // 协程取消必须透传，不能当网络失败
    } catch (e: Throwable) {
        FetchOutcome.Failed(e::class.simpleName ?: "Error", e.message ?: "")
    }

    override suspend fun post(url: String, headers: Map<String, String>, form: Map<String, String>): FetchOutcome = try {
        val body = form.entries.joinToString("&") { (k, v) ->
            (k.encodeURLParameter() + "=" + v.encodeURLParameter())
        }
        val resp = client.post(url) {
            headers.forEach { (k, v) -> header(k, v) }
            contentType(ContentType.Application.FormUrlEncoded)
            setBody(body)
        }
        FetchOutcome.Ok(resp.status.value, resp.bodyAsText())
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e   // 协程取消必须透传
    } catch (e: Throwable) {
        FetchOutcome.Failed(e::class.simpleName ?: "Error", e.message ?: "")
    }
}
