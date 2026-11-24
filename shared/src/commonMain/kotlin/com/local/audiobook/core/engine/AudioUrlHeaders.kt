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

    /**
     * 出口闸：这个 URL 能不能当"音频直链"交给播放器。
     *
     * isDirectAudio 只看扩展名（.mp3/.m4a/...），但网页地址也可能带查询串伪造扩展名，
     * 而且 m3u8 是播放列表不是音频文件，AVPlayer 能吃、原生播放器不一定。
     *
     * 2026-11-24 血泪：https://www.ximalaya.com/sound/{id} 这个**网页**被当成音频播了，
     * AVPlayer 报 -12847（kAudioFormatUnsupportedDataFormatError），用户只看到一句无用的错误码。
     * 网页页面永远不是音频直链 —— 这里显式拦掉门户域名。
     */
    fun isPlayableAudio(url: String): Boolean {
        val ok = url.trim()
        if (!ok.startsWith("http://") && !ok.startsWith("https://")) return false
        // 网页后缀直接否掉（防 /sound/123.html?x=.mp3 这种伪造）。必须在解析 query 之前判。
        val path = ok.substringBefore('?').substringBefore('#').lowercase()
        if (path.endsWith(".html") || path.endsWith(".htm") || path.endsWith(".php")) return false
        val fact = pageHost(ok)
        // 门户/页面域名下永远不是音频文件（音频都在 xmcdn / files.xxx 这类 CDN 上）
        if (fact != null && PAGE_HOSTS.any { fact == it || fact.endsWith("." + it) }) return false
        // 末段必须是音频扩展名
        val clean = ok.substringBefore('?').substringBefore('#').lowercase()
        return AUDIO_EXT.any { clean.endsWith(it) }
    }

    /** 允许"无扩展名但确是音频"的特例：vbus /program/get-source/N 与 302 型音频口 */
    private val RELAY_PATH = listOf("/program/get-source/")

    /**
     * 出口闸的宽松版：在 isPlayableAudio 之外，额外放行三类**已知会被播放器跟 302/直读**的地址：
     *  - 中转过路口（vbus /program/get-source/N → 302 到 files.*.mp3）
     *  - 已知音频 CDN 上的无扩展名资源（xmcdn / files.vbus.cc）
     *
     * 门户域名（ximalaya.com/kuwo.cn/bilibili.com/...）依然一票否决 —— 这条没有任何例外，
     * 因为 https://www.ximalaya.com/sound/{id} 这类网页地址就是这样被当音频播出去、
     * 让 AVPlayer 报 -12847 的。
     */
    fun isPlayableAudioOrRelay(url: String): Boolean {
        val ok = url.trim()
        if (!ok.startsWith("http://") && !ok.startsWith("https://")) return false
        val fact = pageHost(ok)
        if (fact != null && PAGE_HOSTS.any { fact == it || fact.endsWith("." + it) }) return false
        if (isPlayableAudio(ok)) return true
        return RELAY_PATH.any { ok.contains(it) }
    }

    /**
     * 引擎统一出口：所有 extract 返回给播放器的地址都必须先过这里。
     * 不过就抛 ParseFailed，绝不把网页地址当成功结果返回。
     */
    fun requirePlayable(url: String, source: String): String {
        if (!isPlayableAudioOrRelay(url)) {
            throw com.local.audiobook.core.SourceErrors.ParseFailed(
                source + " 只给了网页地址，没给音频直链：" + url.take(120)
            )
        }
        return url
    }

    /** 门户/页面域名：这些域下的地址绝不会是音频文件（音频都在 xmcdn 这类 CDN 上） */
    private val PAGE_HOSTS = listOf(
        "ximalaya.com", "ximalaya.cn", "ximalaya.net",
        "kuwo.cn", "bilibili.com", "b23.tv", "qingting.fm", "qtfm.cn",
        "music.163.com", "163.com", "y.qq.com",
    )

    /** 取去掉端口和用户信息的 host，用于门户域名判断 */
    private fun pageHost(url: String): String? =
        url.substringAfter("://", missingDelimiterValue = "")
            .substringBefore('/')
            .substringAfterLast('@')
            .substringBefore(':')
            .takeIf { it.isNotEmpty() }
            ?.lowercase()

    fun headersFor(audioUrl: String): Map<String, String> =
        if (isAudioHost(audioUrl))
            mapOf("User-Agent" to SearchRoutes.WEB_UA, "Referer" to "https://www.ximalaya.com/")
        else
            emptyMap()
}
