package com.local.audiobook.core

import com.local.audiobook.core.engine.AudioUrlHeaders
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 出口闸矩阵（v1.4.9 审计）：逐个源拿真实地址形态过一遍。
 * 目的：发现哪些源的正常地址会被误杀（那会直接让该源永远播不了）。
 */
class GateMatrixTest {

    /** 各源实际返回的地址形态（实测样本） */
    private val samples = mapOf(
        "ximalaya-open" to "http://aod.cos.tx.xmcdn.com/storages/48cd/1.mp3",
        "ximalaya(登录版)" to "http://aod.cos.tx.xmcdn.com/storages/48cd/1.mp3",
        "kuwo" to "https://kw-bj.kuwo.cn/ae9994a9/nf/resource/n1/69/32/588957081.mp3",
        "bilibili" to "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/11/22/33.m4s?deadline=1",
        "qingting" to "https://audio.qtfm.cn/audiostream/redirect/403408/26955208?access_token=&sign=a502",
        "netease(代理)" to "https://api.qijieya.cn/meting/?server=netease&type=url&id=186016",
        "netease(直链)" to "http://m701.music.126.net/2024/x/song.mp3",
        "vbus(中转)" to "https://www.vbus.cc/program/get-source/5893",
        "ytysxs" to "https://mp3.ytysxs.top/2024/10803/001-005.mp3",
        "ting15" to "https://oss-links.guoguo.org.cn/uploads/t010/a.m4a",
        "模板站(generic)" to "https://www.qmtsw.com/mp3/21170-0-1.mp3",
    )

    @Test
    fun everySourceRealUrlMustPassGate() {
        val blocked = samples.filter { !AudioUrlHeaders.isPlayableAudioOrRelay(it.value) }
        assertTrue(
            blocked.isEmpty(),
            "这些源的真实地址被误杀了（该源会永远播不了）：" + blocked.keys
        )
    }

    /**
     * vod 源的限制要写成测试，而不是靠静默失败。
     * 实测：VodSource 会产出 .m3u8 / .mp4 / .php 三类地址；
     * 出口闸的 AUDIO_EXT 白名单只有 m3u8，mp4 和 php 会被 BLOCK ——
     * 这由 VodSource.extract 自己用 isDirectAudio 拦下，闸门只是兜底。
     * 把它断言出来，以后谁放宽白名单会立刻看到。
     */
    @Test
    fun vodSourceKnownLimitsAreExplicit() {
        assertTrue(AudioUrlHeaders.isPlayableAudioOrRelay("https://x.com/a/index.m3u8"), "m3u8 应放行")
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://x.com/a/b.mp4"), "mp4 目前不放行（vod 已知限制）")
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://x.com/a/b.php?id=1"), "无扩展名 php 不放行（vod 已知限制）")
    }

    @Test
    fun webPagesStillBlocked() {
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://www.ximalaya.com/sound/1011694179"))
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://www.kuwo.cn/play_detail/123"))
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://www.bilibili.com/video/BV1xx"))
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://www.qingting.fm/channels/1"))
        assertFalse(AudioUrlHeaders.isPlayableAudioOrRelay("https://music.163.com/song?id=1"))
    }
}
