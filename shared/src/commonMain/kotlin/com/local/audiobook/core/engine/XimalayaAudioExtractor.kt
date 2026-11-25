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

        // ============ 级3：客户端通道 track/baseInfo（2026-11-25 破局） ============
        //
        // 旧实现在这里打 `www.ximalaya.com/revision/play/v1/audio` —— 那个端点已被 dws 风控
        // 接管，要浏览器指纹算出的 xm-sign，命令行侧复刻不了，匿名/假 Cookie 全部 404。
        // 官方客户端走的是 mobile 通道，只要登录 Cookie，不要指纹。实测：
        //   免费集 → isAuthorized=true，playUrl64 = /mobile/redirect/free/play/{id}/1
        //            → 302 → audiopay.cos.tx.xmcdn.com/...m4a?buy_key=...&sign=...（200 audio/x-m4a）
        //   会员集 → 带会员 Cookie 时 isAuthorized=true，同样给 redirect 链
        //   无权限 → isAuthorized=false、playUrl64=null（这是「没权限」，不是「接口坏了」）
        //
        // **这个接口不需要 Cookie 也能问**（免费集会直接给地址），所以不再「无 Cookie 直接抛」——
        // 那样会让未登录用户连前 20 集免费内容都听不了。
        val cookie = cookieProvider.cookie()
        val headers = OpenRoutes.clientHeaders() +
            (cookie?.let { mapOf("Cookie" to it) } ?: emptyMap())

        val resp = throttle.run { fetcher.get(OpenRoutes.trackBaseInfo(trackId, 0L), headers) }
        if (resp !is FetchOutcome.Ok) {
            val f = resp as FetchOutcome.Failed
            throw SourceErrors.Network(f.kind)
        }
        val info = parse(resp.text) ?: throw SourceErrors.ParseFailed("单集接口响应非JSON")
        fun strOf(k: String): String {
            val v = info[k] as? kotlinx.serialization.json.JsonPrimitive ?: return ""
            if (v is kotlinx.serialization.json.JsonNull) return ""
            return v.content
        }
        if (strOf("ret") != "0") {
            throw SourceErrors.ParseFailed("单集接口返回 ret=" + strOf("ret"))
        }

        // 优先 HQ（aacv1 64k），其次 64k，再次 32k。空串/null 都跳过。
        fun pick(vararg keys: String): String {
            for (k in keys) {
                val v = strOf(k)
                if (v.isNotBlank()) return v
            }
            return ""
        }
        val picked = pick("playPathAacv164", "playUrl64", "playPathAacv224", "playUrl32")
        if (picked.isBlank()) {
            // 有地址字段但全空 → 说明这一集需要权限（会员未开通 / 未登录 / 超出免费集）
            val authorized = strOf("isAuthorized") == "true"
            val free = strOf("isFree") == "true"
            val msg = when {
                !authorized && cookie == null -> "这一集需要登录喜马拉雅账号"
                !authorized && !free -> "这一集需要会员权限（前 20 集免费，之后需开通会员）"
                !authorized -> "没有权限播放这一集"
                else -> "上游未返回可播放地址"
            }
            throw SourceErrors.Vip(msg)
        }
        // redirect 链有几秒时效，expiresInSeconds 给保守值；播放器会自己跟 302（loader 已支持）。
        return ExtractedAudio(picked, emptyMap(), 3_600L)
    }

    // ---- 旧的 revision/play/v1/audio 实现保留在 git 历史里，别再修它 ----
    @Suppress("unused")
    private suspend fun legacyPlayV1Audio(): Nothing =
        throw SourceErrors.ParseFailed("revision/play/v1/audio 需要 xm-sign 指纹签名，已弃用")

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
