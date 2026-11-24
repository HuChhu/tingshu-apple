package com.local.audiobook.core.engine

/**
 * ============================================================
 *  多级音频地址提取器（Multistep Audio Extractor）
 * ============================================================
 *
 * 【设计来源】参考「我的听书」的五级提取器结构
 *   AudioUrlDirectExtractor / JsoupExtractor / JsonExtractor /
 *   CustomExtractor / WebViewExtractor —— 按其难度递增排列。
 *   本项目为独立实现，只借鉴「分级降级」这一结构思想，零代码复用。
 *
 * 【为什么分级】
 *   不同站点取播放地址的难度天差地别：
 *     简单站：响应里直接给 .m4a 链接
 *     中等站：藏在 HTML 的 <audio src> 或 JSON 字段里
 *     困难站：要签名、要登录态、要 WebView 嗅探
 *   用统一的高配方案去打简单站是浪费，用低配方案打困难站必然失败。
 *   所以按「从便宜到昂贵」排序，命中即停。
 *
 * 【纪律】
 *   ① 每级必须无副作用、可独立测试
 *   ② 命中就返回，不继续尝试后面的级
 *   ③ 全部失败才报错，不猜、不硬造地址
 *   ④ 耗时上限由调用方控制（引擎层 RequestThrottle）
 */
object MultistepAudioExtractor {

    /** 提取失败原因（各级共用，便于定位是哪一级全军覆没） */
    sealed class ExtractError(message: String) : Exception(message) {
        object NotDirectLink : ExtractError("不是音频直链")
        object NoHtmlMatch : ExtractError("HTML 里没找到音频地址")
        object NoJsonField : ExtractError("JSON 里没找到音频字段")
        object NoCustomRule : ExtractError("自定义规则未命中")
        object NeedsWebView : ExtractError("需要 WebView 嗅探")
        object AllFailed : ExtractError("全部提取级失败")
    }

    /**
     * 一级提取结果。
     *
     * url 必须是音频直链 —— 构造时就校验，网页地址根本无法被装进 Hit。
     * 旧实现让网页 URL 流到播放器，AVPlayer 报 -12847（格式不支持）。
     */
    data class Hit(val url: String, val level: Level, val headers: Map<String, String> = emptyMap()) {
        init {
            require(AudioUrlHeaders.isPlayableAudio(url)) { "不是音频直链不能当命中：" + level.label + " " + url.take(120) }
        }
    }

    /** 提取级别（数值越大越昂贵） */
    enum class Level(val n: Int, val label: String) {
        Direct(1, "直链"),
        Html(2, "HTML 正则"),
        Json(3, "JSON 字段"),
        Custom(4, "自定义规则"),
        WebView(5, "WebView 嗅探"),
    }

    // ---------- 级 1：直链 ----------

    /**
     * 输入本身是否已经是音频直链。
     * 判据：去掉查询串后扩展名在白名单内。
     */
    fun tryDirect(raw: String): Hit? {
        val url = raw.trim()
        if (url.isEmpty()) return null
        if (!url.startsWith("http://") && !url.startsWith("https://")) return null
        if (!AudioUrlHeaders.isDirectAudio(url)) return null
        return Hit(url, Level.Direct, AudioUrlHeaders.headersFor(url))
    }

    // ---------- 级 2：HTML 正则 ----------

    /**
     * 从 HTML 文本里抠音频地址。
     * 覆盖三种最常见的写法：
     *   <audio src="...">
     *   <source src="...">
     *   var xxx = "...m4a"
     */
    fun tryHtml(body: String): Hit? {
        if (body.isEmpty()) return null
        // 纯 JSON 不归 HTML 级管（否则 JSON 里的 url 字段会被 JS 变量正则误捕）
        val head = body.trimStart()
        if (head.startsWith("{") || head.startsWith("[")) return null
        val candidates = mutableListOf<String>()

        // <audio ... src="...">  /  <source ... src="...">
        Regex("""<(?:audio|source)[^>]+src\s*=\s*["']([^"']+)["']""", RegexOption.IGNORE_CASE)
            .findAll(body).forEach { candidates.add(it.groupValues[1]) }

        // JS 变量里的地址：引号包裹且以音频扩展名结尾
        Regex("""["'](https?://[^"'\s]+\.(?:m4a|mp3|aac|flac|m3u8)(?:\?[^"'\s]*)?)["']""",
            RegexOption.IGNORE_CASE)
            .findAll(body).forEach { candidates.add(it.groupValues[1]) }

        // 允许 // 开头的协议相对地址，补全后再判断
        val hit = candidates.firstOrNull {
            (it.startsWith("http") || it.startsWith("//")) && AudioUrlHeaders.isPlayableAudio(normalize(it, body))
        }
        return hit?.let {
            val full = normalize(it, body)
            Hit(full, Level.Html, AudioUrlHeaders.headersFor(full))
        }
    }

    // ---------- 级 3：JSON 字段 ----------

    /**
     * 从 JSON 文本里找音频字段。
     * 按常见字段名优先级尝试，值必须是 http 开头的音频地址。
     */
    fun tryJson(body: String): Hit? {
        if (body.isEmpty() || !body.trimStart().startsWith("{") && !body.trimStart().startsWith("[")) return null

        val fieldNames = listOf(
            "playUrl", "play_url", "playPath", "play_path",
            "audioUrl", "audio_url", "audioPath",
            "url", "src", "source", "streamUrl", "stream_url",
            "m4a", "mp3", "hlsUrl", "hls_url",
        )
        for (name in fieldNames) {
            val re = Regex("""["']$name["']\s*:\s*["'](https?://[^"']+)["']""", RegexOption.IGNORE_CASE)
            val m = re.find(body) ?: continue
            val url = m.groupValues[1]
            // 字段名对上但值是网页地址（常见于 "url" 字段通用命名）→ 当没命中，继续试下一个字段
            val full = normalize(url, body)
            if (!AudioUrlHeaders.isPlayableAudio(full)) continue
            return Hit(full, Level.Json, AudioUrlHeaders.headersFor(full))
        }
        return null
    }

    // ---------- 级 4：自定义规则 ----------

    /**
     * 自定义规则：调用方提供 (body) -> 候选地址 的函数。
     * 用于签名站、加密站这种通用规则覆盖不了的情况。
     */
    fun tryCustom(body: String, rule: ((String) -> String?)?): Hit? {
        if (rule == null) return null
        val raw = rule(body) ?: return null
        if (!raw.startsWith("http")) return null
        val full = normalize(raw, body)
        if (!AudioUrlHeaders.isPlayableAudio(full)) return null
        return Hit(full, Level.Custom, AudioUrlHeaders.headersFor(full))
    }

    // ---------- 统一入口 ----------

    /**
     * 依次尝试 级1→级4。级5（WebView）由平台层调用，不在本函数内。
     *
     * @param raw         原始输入（可能是直链、可能是页面 URL）
     * @param bodyFetcher 给定 URL 取回文本；返回 null 表示取不到
     * @param customRule  自定义提取规则
     */
    suspend fun extract(
        raw: String,
        bodyFetcher: suspend (String) -> String?,
        customRule: ((String) -> String?)? = null,
    ): Hit {
        // 级 1：输入本身是直链
        tryDirect(raw)?.let { return check(it) }

        // 取正文（级 2/3/4 都要用）
        val body = bodyFetcher(raw) ?: throw ExtractError.AllFailed

        // 级 2：HTML
        tryHtml(body)?.let { return check(it) }

        // 级 3：JSON
        tryJson(body)?.let { return check(it) }

        // 级 4：自定义
        tryCustom(body, customRule)?.let { return check(it) }

        // 级 5 需要平台层接手（iOS: WKWebView 嗅探 / Android: WebView）
        throw ExtractError.NeedsWebView
    }

    /**
     * 出口闸：Hit 交给播放器前必须校验。
     *
     * 各级正则都可能抠出**网页**地址（例如页面里恰好有 "src":"https://www.ximalaya.com/sound/1"），
     * 原样返回会让 AVPlayer 拿到 text/html 报 -12847。这里统一过 AudioUrlHeaders 的出口判定。
     */
    /** extract 内部统一出口：抠出来的东西不是音频就当作"这一级没命中"，继续降级 */
    private fun check(hit: Hit): Hit {
        if (!AudioUrlHeaders.isPlayableAudioOrRelay(hit.url)) throw ExtractError.NoHtmlMatch
        return hit
    }

    fun requirePlayableHit(hit: Hit): Hit {
        if (!AudioUrlHeaders.isPlayableAudioOrRelay(hit.url)) {
            throw ExtractError.NoCustomRule
        }
        return hit
    }

    /** 相对地址补全：// 开头补 https:，/ 开头用 base 的 host */
    private fun normalize(url: String, body: String): String = when {
        url.startsWith("http") -> url
        url.startsWith("//") -> "https:$url"
        url.startsWith("/") -> {
            val m = Regex("""https?://[a-zA-Z0-9.-]+""").find(body)
            (m?.value ?: "") + url
        }
        else -> url
    }
}
