package com.local.audiobook.core.engine

import com.local.audiobook.core.AudioExtractor
import com.local.audiobook.core.CookieProvider
import com.local.audiobook.core.ExtractedAudio
import com.local.audiobook.core.SourceErrors
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.ErrorClassifier
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.data.ximalaya.XimalayaLinkParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

// 播放地址提取器（1–3 级思想）：
// 级1 直链（输入已是音频文件 URL，零请求）→
// 级2 HTML 解析（ksoup，预留接口，当前主路线非网页，不实现）→
// 级3 官方播放接口 + Cookie（bridge get_audio_url 语义对齐：src/url/playUrl 回退链，expires 3600s）。
// 失败按 ErrorClassifier 分类抛 SourceErrors，级间不自动重试（不硬冲）。
class XimalayaAudioExtractor(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    private val cookieProvider: CookieProvider,
) : AudioExtractor {

    override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
        // 级1：直链（零请求，最快）
        if (AudioUrlHeaders.isDirectAudio(url)) {
            return ExtractedAudio(url, AudioUrlHeaders.headersFor(url), 0L)
        }

        // 级2/4：多级提取器给出的 HTML / JSON / 自定义命中（有就省掉官方接口一次请求）
        // 注意：这里只对「输入本身像页面 URL」的情况尝试，纯数字 trackId 直接走官方接口
        val looksLikePage = url.startsWith("http") && !url.all { ch -> ch.isDigit() }
        if (looksLikePage) {
            try {
                val hit = MultistepAudioExtractor.extract(
                    raw = url,
                    bodyFetcher = { target ->
                        val r = throttle.run { fetcher.get(target, AudioUrlHeaders.headersFor(target)) }
                        (r as? FetchOutcome.Ok)?.text
                    },
                )
                if (hit.level != MultistepAudioExtractor.Level.Direct) {
                    guardPlayable(hit.url, "multistep:" + hit.level.label)
                    return ExtractedAudio(hit.url, hit.headers, 0L)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e   // 协程取消必须透传，否则切源/退出时旧请求继续跑满超时
            } catch (e: Throwable) {
                // 提取器失败不致命：继续走官方接口
            }
        }
        // trackId 解析统一走 XimalayaLinkParser（/sound/{id}、?trackId=）；
        // 纯数字输入按本 API 的约定解释为 trackId（extract 是 track 作用域，LinkParser 的纯数字=albumId 语义不变）
        val trackId = XimalayaLinkParser.parse(url).trackId
            ?: url.trim().takeIf { it.isNotEmpty() && it.all { ch -> ch.isDigit() } }?.toLongOrNull()
            ?: throw SourceErrors.ParseFailed("无法解析 trackId：" + url)

        // 预检（对齐桥 get_audio_url 的 has_login 语义 + live 实证：匿名打播放端点=404 HTML 干扰分类）：
        // 无 Cookie 直接 Auth，不发请求——错误类型更准（Auth 而非 ParseFailed），还省一次注定失败的请求。
        // iOS 壳消费 SourceErrors.Auth → 「去登录」文案（SharedBridge 错误族映射）。
        if (cookieProvider.cookie() == null) throw SourceErrors.Auth("本地无登录凭证，去登录")

        // 级3：官方播放接口（需登录 Cookie）
        val base = mapOf(
            "User-Agent" to SearchRoutes.WEB_UA,
            "Referer" to SearchRoutes.WEB_BASE + "/",
            "Accept" to "application/json",
        )
        val cookie = cookieProvider.cookie()
        val headers = if (cookie != null) base + mapOf("Cookie" to cookie) else base

        val resp = throttle.run { fetcher.get(DetailRoutes.playAudio(trackId), headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)

        val json = parse(resp.text) ?: throw SourceErrors.ParseFailed("播放接口响应非JSON")
        val (status, err) = ErrorClassifier.classifyJson(resp.httpStatus, json)
        if (status == "need_login") {
            cookieProvider.refresh()   // 一次，不重试请求本身
            throw err ?: SourceErrors.Auth("需要登录")
        }
        if (status != "ok") {
            // 区分「要会员」和「其它异常」：上游常见文案/字段
            val raw = json.toString()
            if (raw.contains("vip", true) || raw.contains("付费", true) || raw.contains("会员", true)) {
                throw err ?: SourceErrors.Vip("这一章需要喜马拉雅会员")
            }
            throw err ?: SourceErrors.ParseFailed("播放接口分类异常：" + status)
        }

        val inner = json["data"] as? JsonObject
        val audioUrl = AlbumNormalizer.str(inner, "src", "url", "playUrl")
        if (audioUrl.isEmpty()) throw SourceErrors.ParseFailed("上游未返回可播放地址")
        guardPlayable(audioUrl, "play/v1/audio")

        // 出口校验：上游 data.src/url/playUrl 有可能是网页地址（实测 /sound/{id} 就是 200 text/html），
        // 直接交给播放器只会得到 -12847。这里拦成 ParseFailed，让壳侧能显示可读原因。
        AudioUrlHeaders.requirePlayable(audioUrl, "喜马拉雅播放接口")

        // 头部纪律：audio host 精确匹配才注入；错配=空 map
        return ExtractedAudio(audioUrl, AudioUrlHeaders.headersFor(audioUrl), 3_600L)
    }

    /**
     * 出口闸（2026-11-24 P0）。
     *
     * 真机日志：我们把 https://www.ximalaya.com/sound/{id} 这个网页当成音频播了，
     * AVPlayer 报 -12847。原因：上游字段的值被当“地址”直接透传。
     * 从此以后，不是音频直链就当失败处理，绝不把网页地址当成功结果返回。
     */
    private fun guardPlayable(url: String, from: String) {
        if (AudioUrlHeaders.isPlayableAudio(url)) return
        throw SourceErrors.ParseFailed(
            "源站只给了网页地址，没给音频直链（" + from + "）: " + url.take(120)
        )
    }

    private fun parse(text: String): JsonObject? =
        runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
}
