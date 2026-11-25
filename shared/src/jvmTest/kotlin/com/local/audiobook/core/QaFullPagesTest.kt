package com.local.audiobook.core

import com.local.audiobook.core.engine.TemplateSites
import com.local.audiobook.core.net.KtorJsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.*
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

class QaFullPagesTest {
    @Test
    fun tplFullPages() = runBlocking {
        val client = HttpClient(CIO) { install(HttpTimeout) { requestTimeoutMillis = 90_000 } }
        val cases = mapOf(
            "qmtsw" to "https://www.qmtsw.com/show/21170.html",
            "aisongli" to "https://www.aisongli.com/tingshu/1801.html",
            "tingworld" to "http://www.tingworld.com/ting/112441.html",
        )
        for ((key, url) in cases) {
            val site = TemplateSites.byKey(key, KtorJsonFetcher(client), RequestThrottle(1000L, { System.currentTimeMillis() })) ?: continue
            val t0 = System.currentTimeMillis()
            val d = runCatching { site.bookDetail(url, true, true) }   // loadFullPages=true
            val ms = System.currentTimeMillis() - t0
            // 【2026-11-25】以前这里只有 println —— 无论成功失败都算测试通过，永远绿。
            // 现在至少断言「网络成功且拿到章节」，失败要红。
            // 注意：模板站本来就不看 loadFullPages（Html 模式只发 1 次请求），
            // 所以这里验证的是「详情能取到」，不是「翻页生效」。
            d.fold({
                println("TPL " + key + " fullPages=true eps=" + it.episodes.size + " ms=" + ms)
                assertTrue(it.episodes.isNotEmpty(), key + " 详情取到但章节为空")
            }, {
                println("TPL " + key + " ERR " + it.message + " ms=" + ms)
                fail(key + " 请求失败：" + it.message)
            })
        }
    }
}