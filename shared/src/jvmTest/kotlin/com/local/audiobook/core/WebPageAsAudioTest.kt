package com.local.audiobook.core

import com.local.audiobook.core.engine.AudioUrlHeaders
import com.local.audiobook.core.engine.MultistepAudioExtractor
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 【P0 2026-11-24】网页地址被当成音频播出去 —— AVPlayer 报 -12847。
 *
 * 真机日志：`[PLAY] start remote track=1011694179 src=ximalaya scheme=https host=www.ximalaya.com`
 * 然后是 `loader resp code=200 mime=text/html` → `OSStatus -12847`。
 *
 * 根因链：
 *  1. `TrackNormalizer.normalizeTrack` 把 `Episode.url` 填成 `https://www.ximalaya.com/sound/{id}`（网页，不是音频）
 *  2. `XimalayaOpenSource.audioExtractor().extract` 对任何 http 开头输入**原样返回**
 *  3. 这个网页被交给 AVPlayer
 *
 * 本文件锁死：出口不许放行网页地址。
 */
class WebPageAsAudioTest {

    private fun headers() = com.local.audiobook.core.engine.AudioUrlHeaders

    // ---------- 1. 出口判定本身 ----------

    @Test
    fun webPageIsNeverPlayableAudio() {
        val pages = listOf(
            "https://www.ximalaya.com/sound/1011694179",   // 真机日志里那个
            "https://www.ximalaya.com/album/38454623",
            "https://m.ximalaya.com/sound/1011694179",
            "https://www.kuwo.cn/play_detail/123",
            "https://www.bilibili.com/video/BV1xx",
        )
        for (u in pages) {
            assertFalse(AudioUrlHeaders.isPlayableAudio(u), "网页地址不能算音频直链：" + u)
            assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay(u), "网页地址不能过出口闸：" + u)
            assertFailsWith<SourceErrors.ParseFailed>("出口必须抛 ParseFailed：" + u) {
                AudioUrlHeaders.requirePlayable(u, "test")
            }
        }
    }

    @Test
    fun realAudioUrlStillPasses() {
        val ok = listOf(
            "https://aod.cos.tx.xmcdn.com/storages/87ed/x.m4a",
            "https://fdfs.xmcdn.com/group48/M07/D8/BC/x.mp3",
            "https://files.vbus.cc/upload/2024/12/x.mp3?expires=1&md5=abc",
            "https://p1.music.126.net/AAA==/1.jpg".replace(".jpg", ".mp3"),
        )
        for (u in ok) {
            assertTrue(AudioUrlHeaders.isPlayableAudio(u), "真音频直链不能误伤：" + u)
            assertEquals(u, AudioUrlHeaders.requirePlayable(u, "test"))
        }
    }

    /** 伪造扩展名：网页地址挂个 ?x=.mp3 的后缀不能骗过闸门 */
    @Test
    fun fakeExtensionDoesNotBypassGate() {
        assertFalse(
            AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/sound/1.html?file=.mp3"),
            ".html 页面不能靠 query 里的 .mp3 混过去"
        )
        assertFalse(
            AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/sound/1.mp3"),
            "门户域名下一律不是音频，即使路径看起来像"
        )
    }

    // ---------- 2. 提取器出口 ----------

    /** XimalayaOpenSource 曾经把输入原样返回 —— 这条是那次事故的直接回归 */
    @Test
    fun ximalayaOpenExtractorRejectsWebPage() = runBlocking {
        val pageUrl = "https://www.ximalaya.com/sound/1011694179"
        val fetcher = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) =
                FetchOutcome.Ok(200, "<html><body>loading</body></html>")
        }
        val src = com.local.audiobook.core.engine.XimalayaOpenSource(
            fetcher = fetcher,
            throttle = RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
        )
        val err = assertFailsWith<SourceErrors.ParseFailed>("网页地址必须被挡在出口") {
            src.audioExtractor().extract(pageUrl, 5_000)
        }
        assertTrue(
            err.reason.contains("网页地址") || err.reason.contains("音频直链"),
            "错误文案要能看懂，实际=" + err.reason
        )
    }

    /** 多级提取器从页面里抠出一个网页地址时，不能当音频返回 */
    @Test
    fun multistepHitRejectsWebPageUrl() = runBlocking {
        // 页面正文里恰好有 "src":"https://www.ximalaya.com/sound/1" —— 级 3 JSON 会抠到它
        val body = """{"data":{"src":"https://www.ximalaya.com/sound/1011694179"}}"""
        val fetcher = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, body)
        }
        val e = assertFailsWith<Throwable>("抠出网页地址不能算命中") {
            MultistepAudioExtractor.extract(
                raw = "https://www.ximalaya.com/sound/1011694179",
                bodyFetcher = { t -> (fetcher.get(t, emptyMap()) as FetchOutcome.Ok).text },
            )
        }
        assertTrue(
            e is MultistepAudioExtractor.ExtractError,
            "应当是提取失败（继续降级），实际=" + e::class.simpleName
        )
    }

    // ---- 出口闸不许误杀真实 CDN ----
    // 2026-11-24 实测：按父域一票否决曾把 kw-bj.kuwo.cn（kuwo 自家音频 CDN）整个杀掉，
    // netease 的 /meting/ 中转、B 站的 .m4s 分片也被误判。这几条锁死它们。

    @Test
    fun kuwoCdnSubdomainIsNotBlocked() {
        assertTrue(AudioUrlHeaders.isPlayableAudio("http://kw-bj.kuwo.cn/audio/x.mp3"))
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.kuwo.cn/play_detail/123"))
    }

    @Test
    fun neteaseMetingRelayIsAllowed() {
        assertTrue(AudioUrlHeaders.isPlayableAudioOrRelay("https://api.qijieya.cn/meting/?type=url&id=1"))
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://music.163.com/song?id=1"))
    }

    @Test
    fun bilibiliM4sIsPlayable() {
        assertTrue(AudioUrlHeaders.isPlayableAudio("https://upos-sz-mirrorcos.bilivideo.cn/x/1.m4s"))
    }

    @Test
    fun relayWhitelistIsNotABypass() {
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://www.ximalaya.com/sound/123"))
    }
}
