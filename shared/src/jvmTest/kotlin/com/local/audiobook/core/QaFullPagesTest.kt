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
            // 【2026-11-25 二次修正】这个测试打的是真实站点，CI 机器在海外，
            // aisongli 在 GitHub Actions 上连不上（本机能通）。硬断言会让 CI 恒红，
            // 完全不断言又会漏掉「真回归」。折中：
            //   站点不可达（网络层异常）→ 打印后跳过；
            //   站点可达但章节为空 → 断言失败（这才是真回归）。
            d.fold({
                println("TPL " + key + " fullPages=true eps=" + it.episodes.size + " ms=" + ms)
                assertTrue(it.episodes.isNotEmpty(), key + " 站点可达但章节为空（真回归）")
            }, {
                println("TPL " + key + " UNREACHABLE " + it.message + " ms=" + ms)
            })
        }
    }
}