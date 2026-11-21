package com.local.audiobook.core.engine

// 头部纪律（§19.2 血泪教训）：按 host 精确匹配才注入 UA+Referer；不匹配必须原样（空 headers）。
// 纯函数，单测覆盖正例与错配必须不动 headers 的用例。
object AudioUrlHeaders {

    private val AUDIO_HOSTS = listOf("ximalaya.com", "xmcdn.com")
    private val AUDIO_EXT = listOf(".mp3", ".m4a", ".aac", ".flac", ".m3u8")

    fun hostOf(url: String): String? =
        url.substringAfter("://", missingDelimiterValue = "")
            .substringBefore('/')
            .substringBefore(':')
            .takeIf { it.isNotEmpty() }
            ?.lowercase()

    // host == 域 或以「.域」结尾（子域）。防 fakeximalaya.com 这类后缀伪装。
    fun isAudioHost(url: String): Boolean {
        val h = hostOf(url) ?: return false
        return AUDIO_HOSTS.any { h == it || h.endsWith("." + it) }
    }

    // 级1 判定：输入已是音频直链（扩展名判断，剥查询串）
    fun isDirectAudio(url: String): Boolean {
        val clean = url.substringBefore('?').lowercase()
        return AUDIO_EXT.any { clean.endsWith(it) }
    }

    fun headersFor(audioUrl: String): Map<String, String> =
        if (isAudioHost(audioUrl))
            mapOf("User-Agent" to SearchRoutes.WEB_UA, "Referer" to "https://www.ximalaya.com/")
        else
            emptyMap()
}
