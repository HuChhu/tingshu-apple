package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import com.local.audiobook.core.BookDetail
import com.local.audiobook.core.Capabilities
import com.local.audiobook.core.Episode
import com.local.audiobook.core.ExtractedAudio
import com.local.audiobook.core.SearchResult
import com.local.audiobook.core.SourceActions
import com.local.audiobook.core.SourceErrors
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * 模板化听书站引擎（Template TingSite Engine）
 *
 * 【来源】反编译 14 个 jar 后发现：31 个源类继承同一个基类 XmTingSite，
 * 差别只是一个 10 参数构造函数，解析逻辑完全一样。
 *
 * 【基类构造签名（从 dex 还原）】
 *   (sid, base, siteName, siteDesc, cats, bookHrefMatch:Regex, referrer, chapterRegex:Regex, Z, Z)
 *
 * 【音频提取（基类三级回退，实测 qmtsw 验证）】
 *   ① var now="([^"]+)"
 *   ② https?://[^\s"'<>]+?\.m4a[^\s"'<>]*
 *   ③ https?://[^\s"'<>]+?\.mp3[^\s"'<>]*
 *
 * 【实测 2026-11-23】
 *   qmtsw.com 分类页 → 10 本；书籍页 → 218 章；播放页 → 2 条 m4a
 *   下载 → 4,308,846 字节 M4A，ftyp/moov/mdat 完整
 */
class TemplateTingSite(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    val base: String,
    val siteName: String,
    val siteDesc: String = "",
    val cats: List<Pair<String, String>> = emptyList(),
    val bookHrefPattern: String = "/show/(\\d+)\\.html",
    /**
     * 章节链接正则（在书籍页 HTML 里 find）。
     * 捕获组 1 = 书号，2 = 卷/页，3 = 集。匹配不到的站用 chapterMode 切换模式。
     */
    val chapterPattern: String = "/play/(\\d+)-(\\d+)-(\\d+)\\.html",
    /** 章节 URL 拼接前缀（默认 /play/；tingdada 用 /mp3/） */
    val chapterPrefix: String = "/play/",
    val referrer: String = "",
    /**
     * 章节来源模式：
     *  - html（默认）：在书籍页 HTML 里 find chapterPattern 拼章节 URL
     *  - playlist：WordPress audioigniter 播放器，书籍页里有 data-tracks-url，
     *              逐个拉 JSON 数组（[{title,audio,cover}]），音频直出。
     *              ytysxs 走这条（100 集/列表，一本书 5~6 个列表）。
     *  - json：书籍页里有数据接口，返回 JSON 节目列表（vbus /api/v1/program/list?album_id=）
     */
    val chapterMode: ChapterMode = ChapterMode.Html,
    /** chapterMode=json 时的节目列表 URL 模板，{id} 换成书籍 URL 里的数字 */
    val jsonApiPattern: String = "",
    /** chapterMode=json 时 JSON 里节目数组的字段名（data.programs / data.list ...） */
    val jsonListKey: String = "data",
    /** chapterMode=json 时单条节目的 链接字段 / 音频字段 / 标题字段 / 封面字段 */
    val jsonUrlKey: String = "url",
    val jsonAudioKey: String = "",
    val jsonTitleKey: String = "title",
    val jsonCoverKey: String = "",
    /** chapterMode=HtmlPages 时第 N 页 URL 模板：{url} = 首章 URL，{page} = 页码（从 2 开始） */
    val htmlPagePattern: String = "{url}/{page}",
    /** HtmlPages 最多翻多少页（防死循环；vbus 20 条/页，40 页 = 800 条） */
    val htmlMaxPages: Int = 40,
    /** HtmlPages 第二页的 {page} 值（vbus=2；yuetingba 是按集数偏移 =40） */
    val htmlPageStart: Int = 2,
    /** HtmlPages 每页 {page} 增量 */
    val htmlPageStep: Int = 1,
    /** 章节 URL 取哪个捕获组的整段路径（-1 = 整个匹配就是 URL；0 = 默认 3 段拼接） */
    val chapterPathGroup: Int = 0,
    /**
     * 播放接口（POST 表单取音频）。ting15：/?s=api-getneoplay
     * 表单从播放页的 <meta name="_b/_p/_cp/_m"> 取，请求头从 <meta name="_c/_l"> 取。
     */
    val audioApiPattern: String = "",
    /**
     * 播放接口 URL 模板（GET）。{url} = 章节页 URL，{id} = 章节 slug。
     * yuetingba���GET /api/app/docs-listen/<tingId>/audio-url，响应体直接就是音频 URL 文本。
     */
    val audioApiUrlPattern: String = "",
    override val sourceId: String,
) : SourceActions {

    /**
     * 章节来源模式：
     *  - Html      ：书籍页 HTML 里正则抓章节链接（默认，多数站）
     *  - Playlist  ：WordPress audioigniter 播放器，data-tracks-url 拉 JSON（ytysxs）
     *  - Json      ：书籍页有数据接口（vbus 的接口不支持专辑过滤，改用 HtmlPages）
     *  - HtmlPages ：书籍页只带一页章节，要按 htmlPagePattern 翻页（vbus /album/1064 → /album/1064/2）
     */
    enum class ChapterMode { Html, Playlist, Json, HtmlPages }

    override val url = base
    override val name = siteName
    override val desc = siteDesc.ifEmpty { "模板站：" + siteName }
    override val capabilities = Capabilities(
        searchable = true,
        discoverable = cats.isNotEmpty(),
        cacheable = true,
        needsWebView = false,
        searchVerifiable = false,
        needsLogin = false,
        multipleEpisodePages = chapterMode == ChapterMode.Playlist,
    )

    override suspend fun search(keywords: String, page: Int): SearchResult {
        if (cats.isEmpty()) {
            return SearchResult(emptyList(), 0, sourceId, page, "该站没配分类")
        }
        val out = mutableListOf<Book>()
        val kw = keywords.trim()
        // 每个分类页最多扫 3 个，凑够 20 本提前收工
        for (c in cats.take(3)) {
            val html = getText(c.second, base) ?: continue
            out.addAll(parseBookList(html))
            if (out.size >= 20) break
        }
        val uniq = out.distinctBy { it.bookUrl }
        val filtered = if (kw.isEmpty()) uniq else uniq.filter { it.title.contains(kw, ignoreCase = true) }
        val result = if (filtered.isNotEmpty()) filtered else uniq.take(10)
        return SearchResult(result, page, sourceId, page,
            if (result.isEmpty()) "没搜到，试试分类浏览" else null)
    }

    suspend fun categoryBooks(catIndex: Int): List<Book> {
        val catUrl = cats.getOrNull(catIndex)?.second ?: return emptyList()
        val html = getText(catUrl, base) ?: return emptyList()
        return parseBookList(html)
    }

    /**
     * 分类页解析。三种情况都兜住：
     *  - href 有 ?query：用 Regex.find 子串匹配（bookHrefPattern 没锚定），toAbs 只取 path
     *  - title 为空：只取 <a> 到 </a> 之间的文本，不跨标签，不做 HTML 实体外的截断
     *  - 书标题本身 >40 字（长书名剧）：上限放到 60，靠"含标点密度"和"像 URL"筛
     */
    private fun parseBookList(html: String): List<Book> {
        val out = LinkedHashMap<String, Book>()
        val idRe = runCatching { Regex(bookHrefPattern) }.getOrElse { return emptyList() }
        val anchorRe = Regex("<a\\s+([^>]*)>", RegexOption.IGNORE_CASE)
        val hrefRe = Regex("href=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val titleRe = Regex("title=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val coverRe = Regex("(?:data-original|data-src|src)=[\"']([^\"']+\\.(?:jpg|jpeg|png|webp))", RegexOption.IGNORE_CASE)

        for (m in anchorRe.findAll(html)) {
            val attrs = m.groupValues[1]
            val href = hrefRe.find(attrs)?.groupValues?.get(1) ?: continue
            val idm = idRe.find(href) ?: continue
            val id = idm.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() } ?: continue
            if (out.containsKey(id)) continue

            val afterIdx = m.range.last + 1
            val endA = html.indexOf("</a>", afterIdx)
            // stopAt 严格夹在 </a> 之内：跨标签抓到的必然是下一块的正文，直接丢弃
            val stopAt = if (endA in afterIdx..minOf(html.length, afterIdx + 400)) endA
                         else minOf(html.length, afterIdx + 200)
            var title = unescape(titleRe.find(attrs)?.groupValues?.get(1)?.trim() ?: "")
            if (title.length < 2) {
                title = unescape(html.substring(afterIdx, stopAt).replace(Regex("<[^>]*>"), " "))
                    .replace(Regex("\\s+"), " ").trim().take(60)
            }
            if (title.length < 2 || title.length > 60 || title.startsWith("http")) continue
            // 正文段落：句读密集或含大量空白，一律不是书名
            if (title.count { it == '，' || it == '。' || it == ',' || it == '.' || it == '?' } >= 2) continue
            if (title.count { it == ' ' } >= 5) continue

            val tail2 = html.substring(afterIdx, minOf(html.length, afterIdx + 500))
            val cover = coverRe.find(tail2)?.groupValues?.get(1)?.let { toAbs(it) } ?: ""

            out[id] = Book(
                sourceId = sourceId,
                bookUrl = toAbs(href),
                title = title,
                author = "",
                coverUrl = cover,
                intro = "",
                albumId = id.tokenLong(),
                trackCount = 0L,
                playCount = 0L,
                isFinished = false,
            )
        }
        return out.values.toList()
    }

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val html = getText(bookUrl, base) ?: throw SourceErrors.NotFound(bookUrl)
        var book = Book(
            sourceId = sourceId,
            bookUrl = bookUrl,
            title = parseTitle(html) ?: "模板站书籍",
            author = Regex("作者[:：]\\s*([^<\\s]{2,20})").find(html)?.groupValues?.get(1) ?: "",
            coverUrl = Regex("<img[^>]+(?:data-original|data-src|src)=[\"']([^\"']+\\.(?:jpg|jpeg|png|webp))")
                .find(html)?.groupValues?.get(1)?.let { toAbs(it) } ?: "",
            intro = "",
            albumId = Regex("/([A-Za-z0-9]+)(?:\\.html|/)?").find(bookUrl)?.groupValues?.get(1)?.tokenLong() ?: 0L,
            trackCount = 0L,
            playCount = 0L,
            // P1-6：32 个模板站大部分不写「已完本」，只写「完结 / 全集 / 连载中」。原文案只认两种，
            // isFinished 恒 false，书架永远不显示「已完结」。统一走 isFinishedHtml()。
            isFinished = isFinishedHtml(html),
        )

        if (!loadEpisodes) return BookDetail(book, emptyList())

        val eps: List<Episode> = when (chapterMode) {
            ChapterMode.Html -> episodesFromHtml(html, book.coverUrl)
            ChapterMode.Playlist -> episodesFromPlaylists(html, bookUrl, book.coverUrl)
            ChapterMode.Json -> episodesFromJsonApi(bookUrl, book.coverUrl)
            // P1-3：原逻辑是「页面包含章节链接就走单页」，导致 Yuetingba 永远只抓第一页。
            // 改为：如果明确配置了 htmlPageStart/htmlPageStep（非默认值），强制走分页。
            // 只有未配置分页参数时，才用「页面有链接就不翻页」的优化。
            ChapterMode.HtmlPages -> {
                val hasCustomPaging = htmlPageStart != 2 || htmlPageStep != 1
                if (!hasCustomPaging && html.contains(chapterToken) && chapterToken.isNotEmpty()) {
                    episodesFromHtml(html, book.coverUrl)
                } else {
                    episodesFromHtmlPages(bookUrl, html, book.coverUrl)
                }
            }
        }
        // 书名里的 "xxx集" / span.bz 是站点自己标的集数，比章节数可信；章节拿不到时至少别显示 0
        book = book.copy(trackCount = if (eps.isNotEmpty()) eps.size.toLong() else book.trackCount)
        return BookDetail(book, eps)
    }

    private fun parseTitle(html: String): String? {
        val raw = Regex("<title>([^<]*)</title>", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
            ?.let { unescape(it) }?.trim() ?: return null
        if (raw.isEmpty()) return null
        // gushiya：《天书墓宅》在线收听-... → 取书名号
        Regex("《([^》]{1,40})》").find(raw)?.groupValues?.get(1)?.trim()?.let { if (it.length >= 2) return it }
        // dt.name / h1 优先于 <title>（<title> 常带站名后缀）
        Regex("<dt[^>]*class=[\"'][^\"']*name[^\"']*[\"'][^>]*>([^<]{2,40})").find(html)
            ?.groupValues?.get(1)?.let { t -> return unescape(t).trim() }
        Regex("<h1[^>]*>([^<]{2,40})</h1>").find(html)
            ?.groupValues?.get(1)?.let { t -> return unescape(t).trim() }
        val cut = raw.substringBefore("_").substringBefore("-").trim()
        return cut.takeIf { it.isNotEmpty() } ?: raw.take(40)
    }

    /**
     * HTML 章节解析。
     *
     * 两层：
     *  ① 默认（chapterPathGroup == 0）：按捕获组 1/2/3 = 书号/卷/集 拼 base + chapterPrefix + key + .html
     *  ② chapterPathGroup > 0（ting15）：章节在分类子目录里，只能截取"整段路径"，拼出来的 URL 必须是原 href
     *
     * 【P0 审计】旧实现的拼接写死是 3 段式，遇到 2 段的章节目录
     * （ting15 的 /wuxiaxuanhuan/1254/0-1.html，group3 不存在 → 默认 "0"）会拼出
     * /…/0-1-0.html —— 3977 章全是死链，detail 却显示成功。现在 URL 必须能对上原 href，
     * 否则宁可不给章节，也不给一串点了不能播的假地址。
     */
    /** 章节模式下的链接路径类型（用于判断页面里是不是已有章节） */
    private val chapterToken: String = when {
        chapterPathGroup < 0 && chapterPattern.contains("/(") -> chapterPattern.substringBefore("(").trimEnd('/')
        else -> chapterPrefix.trimEnd('/')
    }

    private fun episodesFromHtml(html: String, cover: String): List<Episode> {
        val out = mutableListOf<Episode>()
        val seen = mutableSetOf<String>()
        val chRe = runCatching { Regex(chapterPattern) }.getOrNull() ?: return emptyList()
        for (m in chRe.findAll(html)) {
            // chapterPathGroup < 0：整个匹配就是章节 URL（ting15 这种分类子目录站）
            if (chapterPathGroup < 0) {
                val abs = toAbs(m.value)
                if (!seen.add(abs)) continue
                val epNo = m.value.removeSuffix(".html").substringAfterLast("/").substringAfterLast("-")
                    .toLongOrNull()
                out.add(Episode(
                    title = if (epNo != null) "第" + epNo + "集" else "第" + (out.size + 1) + "集",
                    url = abs,
                    trackId = epNo ?: (out.size + 1).toLong(),
                    index = out.size + 1,
                    durationMs = 0L,
                    coverUrl = cover,
                ))
                continue
            }
            val bookId = m.groupValues.getOrNull(1) ?: continue
            val pg = m.groupValues.getOrNull(2) ?: "0"
            val ep = m.groupValues.getOrNull(3) ?: "0"
            val key = bookId + "-" + pg + "-" + ep
            if (!seen.add(key)) continue
            // 拼出来的地址必须真的出现在页面里（说明路径规则对得上），否则跳过这个站
            if (!html.contains(chapterPrefix + key)) continue
            out.add(Episode(
                title = "第" + (out.size + 1) + "集",
                url = base.trimEnd('/') + chapterPrefix + key + ".html",
                trackId = key.replace("-", "").toLongOrNull() ?: 0L,
                index = out.size + 1,
                durationMs = 0L,
                coverUrl = cover,
            ))
        }
        return out
    }

    /** WordPress audioigniter：书籍页里 data-tracks-url="?audioigniter_playlist_id=N"，每页 100 集 */
    private suspend fun episodesFromPlaylists(html: String, bookUrl: String, cover: String): List<Episode> {
        val out = mutableListOf<Episode>()
        val listRe = Regex("data-tracks-url=[\"']([^\"']*audioigniter_playlist_id=\\d+[^\"']*)[\"']")
        // 站内环境里 data-tracks-url="?audioigniter_playlist_id=10816" 是相对地址，要拼到当前书页的 host 上
        val urls = listRe.findAll(html).map { unescape(it.groupValues[1]) }
            // 相对地址（?query / path）一律按书页 URL 解析，不能用 base（会打到首页上）
            .map { u -> if (u.startsWith("http")) u else resolve(bookUrl, u) }
            .distinct().toList()
        for (u in urls) {
            val json = getText(toAbs(unescape(u)), bookUrl) ?: continue
        val arr = runCatching { Json.parseToJsonElement(json) as? JsonArray }.getOrNull() ?: continue
            for (el in arr) {
                val o = el as? JsonObject ?: continue
                val audio = str(o, "audio") ?: continue
                if (audio.isEmpty()) continue
                val t = str(o, "title")?.takeIf { it.isNotBlank() } ?: ("第" + (out.size + 1) + "集")
                out.add(Episode(
                    title = unescape(t),
                    url = audio,
                    trackId = (out.size + 1).toLong(),
                    index = out.size + 1,
                    durationMs = 0L,
                    coverUrl = str(o, "cover") ?: cover,
                ))
            }
        }
        return out
    }

    /** vbus 式：/api/v1/program/list?album_id=N，{data:{programs:[{program_id,program_name,file_path}]}} */
    private suspend fun episodesFromJsonApi(bookUrl: String, cover: String): List<Episode> {
        if (jsonApiPattern.isEmpty()) return emptyList()
        // 书 URL -> 接口 id。三种形态都要吃：
        //   /album/1064          → 1064
        //   /v/1064              → 1064
        //   /book/detail/ab-12/1 → ab-12（非纯数字的 slug 站）
        val segs = bookUrl.substringBefore("?").split("/").filter { it.isNotEmpty() }
        val id = segs.lastOrNull { it.any { ch -> ch.isDigit() } } ?: return emptyList()
        val out = mutableListOf<Episode>()
        for (page in 1..MAX_JSON_PAGES) {
            val url = jsonApiPattern.replace("{id}", id).replace("{page}", page.toString())
            val txt = getText(url, bookUrl)
            if (txt == null) break
            // 接口 404 时可能回 <html>：解析失败直接停，不重试（失败不重试纪律）
            val obj = runCatching { Json.parseToJsonElement(txt) as? JsonObject }.getOrNull() ?: break
            val arr: JsonArray = listAt(obj, jsonListKey) ?: break
            if (arr.isEmpty()) break
            for (el in arr) {
                val o = el as? JsonObject ?: continue
                val link = str(o, jsonUrlKey)
                val audio = if (jsonAudioKey.isNotEmpty()) str(o, jsonAudioKey) else null
                val byAudio: String? = if (!audio.isNullOrBlank()) audio else null
                val byLink: String? = if (!link.isNullOrBlank()) toAbs(link!!) else null
                val real: String = byAudio ?: byLink ?: continue
                // 标题为 null 用序号兜底：宁可显示"第 N 集"也不带一个空标题的条目
                val rawTitle: String = str(o, jsonTitleKey)?.trim() ?: ""
                val title: String = if (rawTitle.isEmpty()) "第" + (out.size + 1) + "集" else unescape(rawTitle)
                out.add(Episode(
                    title = title,
                    url = real,
                    trackId = str(o, "program_id")?.toLongOrNull() ?: (out.size + 1).toLong(),
                    index = out.size + 1,
                    durationMs = 0L,
                    coverUrl = if (jsonCoverKey.isNotEmpty()) str(o, jsonCoverKey) ?: cover else cover,
                ))
            }
            if (arr.size < 20) break
        }
        return out
    }

    /**
     * 分页章节（vbus 这类）：书籍页每页 20 条，第 N 页是 distinct 的 URL。
     * 终止条件三选一先到先得：①本页 0 条 ②本页链接全部见过 ③翻到 htmlMaxPages 上限。
     */
    private suspend fun episodesFromHtmlPages(firstUrl: String, firstHtml: String, cover: String): List<Episode> {
        val out = mutableListOf<Episode>()
        val seen = mutableSetOf<String>()
        val linkRe = LINK_HREF
        // P1-3：用本站的 chapterPattern 匹配章节链接。
        // 但如果 chapterPattern 是默认的 /play/N-N-N.html 格式，而页面链接是 /v/ 格式（vbus），
        // 需要回退到 PROGRAM_LINK（/v/）兜底，否则 vbus 的 HtmlPages 会失效。
        val chapterPatternRegex = runCatching { Regex(chapterPattern) }.getOrNull()
            ?: Regex("^(?:https?://[^/]+)?/v/(\\d+)/?$")
        val isDefaultPlayPattern = chapterPattern.contains("/play/")
        val vbusLinkRegex = Regex("^(?:https?://[^/]+)?/v/(\\d+)/?$")
        var html = firstHtml
        var page = 1
        while (page <= htmlMaxPages) {
            val links = mutableListOf<Pair<String, String>>()   // href -> 标题
            for (m in linkRe.findAll(html)) {
                val href = m.groupValues[1]
                val matched = chapterPatternRegex.containsMatchIn(href) || (isDefaultPlayPattern && vbusLinkRegex.containsMatchIn(href))
                if (!matched) continue
                val abs = toAbs(unescape(href))
                if (!seen.add(abs)) continue
                val title = m.groupValues[2].replace(Regex("<[^>]*>"), " ").trim()
                links.add(abs to title)
            }
            if (links.isEmpty()) break
            for ((abs, t) in links) {
                val id = chapterPatternRegex.find(abs)?.groupValues?.get(1)?.toLongOrNull()
                    ?: vbusLinkRegex.find(abs)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
                out.add(Episode(
                    title = if (t.isBlank()) "第" + (out.size + 1) + "集" else unescape(t),
                    url = abs,
                    trackId = id,
                    index = out.size + 1,
                    durationMs = 0L,
                    coverUrl = cover,
                ))
            }
            page += 1
            if (page > htmlMaxPages) break
            val pageVal = htmlPageStart + (page - 2) * htmlPageStep
            // P1-3：firstUrl 可能带页码后缀（如 /book/detail/<uuid>/0），
            // 直接拼 {page} 会变成 /0/200。
            // 但不能一刀切去掉末尾数字段——/album/1064 的 1064 是书籍 ID，不是页码。
            // 只有末尾数字段等于 htmlPageStart 的初始值（即第一页的页码）时才去掉。
            val trimmed = firstUrl.trimEnd('/')
            val lastSeg = trimmed.substringAfterLast('/')
            // 页码后缀的两种情形：
            // ① 默认分页（htmlPageStart=2）：末尾数字段等于 2 才是页码（如 /album/1064/2）
            // ② 自定义分页（htmlPageStart 非默认）：末尾数字段是页码（如 /book/detail/<uuid>/0）
            //    此时书籍 ID 通常不是纯数字（如 UUID），所以末尾数字段一定是页码
            val isPageSuffix = if (htmlPageStart == 2) {
                lastSeg.toIntOrNull() == 2
            } else {
                lastSeg.toIntOrNull() != null
            }
            val baseUrl = if (isPageSuffix) trimmed.removeSuffix("/" + lastSeg) else trimmed
            html = getText(htmlPagePattern.replace("{url}", baseUrl).replace("{page}", pageVal.toString()), firstUrl)
                ?: break
        }
        return out
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                // 播放接口模式（ting15）：页面里没有音频地址，要 POST 表单才能换出来
                if (audioApiPattern.isNotEmpty()) {
                    audioFromApi(url)?.let { return it }
                }
                // GET 式播放接口（yuetingba）：响应正文就是 mp3 地址
                if (audioApiUrlPattern.isNotEmpty()) {
                    audioFromApiUrl(url)?.let { return it }
                }
                // 章节 URL 本身就是音频（ytysxs playlist 模式）：直接返回，不发请求
                if (AUDIO_EXT.containsMatchIn(url)) {
                    return ExtractedAudio(url, AudioUrlHeaders.headersFor(url), 0L)
                }
                // vbus：/program/get-source/N 是 302 → files.vbus.cc/....mp3，直接给这个 URL，播放器自己跟跳转
                if (GET_SOURCE.containsMatchIn(url)) {
                    return ExtractedAudio(toAbs(url), AudioUrlHeaders.headersFor(toAbs(url)), 0L)
                }
                val html = getText(url, referrer.ifEmpty { base })
                    ?: throw SourceErrors.Network("播放页取不到")

                // ① var now="..." ：可能是绝对地址，也可能是相对路径
                Regex("var now=\\s*[\"']([^\"']+)[\"']").find(html)?.groupValues?.get(1)?.let { v ->
                    val abs = toAbs(unescape(v.trim()))
                    if (AUDIO_EXT.containsMatchIn(abs)) {
                        return ExtractedAudio(abs, AudioUrlHeaders.headersFor(abs), 0L)
                    }
                }
                // ② 页面里 data-tracks-url 的 JSON 播放列表，取第一条音轨
                Regex("data-tracks-url=[\"']([^\"']*audioigniter_playlist_id=\\d+[^\"']*)[\"']")
                    .find(html)?.groupValues?.get(1)?.let { u ->
                        val txt = getText(toAbs(unescape(u)), url)
                        val arr = txt?.let { runCatching { Json.parseToJsonElement(it) as? JsonArray }.getOrNull() }
                        if (arr != null && arr.isNotEmpty()) {
                            val o = arr[0] as? JsonObject
                            val a = o?.let { str(it, "audio") }
                            if (!a.isNullOrBlank()) {
                                return ExtractedAudio(a, AudioUrlHeaders.headersFor(a), 0L)
                            }
                        }
                    }
                // ③ <audio ... src="/program/get-source/5893">
                Regex("<audio[^>]+src=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE).find(html)
                    ?.groupValues?.get(1)?.let { u ->
                        if (GET_SOURCE.containsMatchIn(u)) {
                            val abs = toAbs(u)
                            return ExtractedAudio(abs, AudioUrlHeaders.headersFor(abs), 0L)
                        }
                    }
                // ④ m4a / mp3 / m3u8（要求全大写小写都行；排除 .jpg 之类的伪命中由扩展名后缀保证）
                for (re in AUDIO_RE) {
                    re.find(html)?.value?.let { v ->
                        val clean = unescape(v.trim())
                        if (AUDIO_EXT.containsMatchIn(clean)) {
                            return ExtractedAudio(clean, AudioUrlHeaders.headersFor(clean), 0L)
                        }
                    }
                }
                throw SourceErrors.ParseFailed("播放页没找到音频地址")
            }
        }

    /**
     * yuetingba 式：GET /api/app/docs-listen/<tingId>/audio-url，响应正文就是
     * http://host/myfiles/.../<hash>.mp3?token=..&expire=.. 一条带过期链接。
     * 需要 Referer（站内）否则 302 到 /Error。
     */
    private suspend fun audioFromApiUrl(pageUrl: String): ExtractedAudio? {
        val id = pageUrl.trimEnd('/').substringAfterLast("/")
        if (id.isEmpty()) return null
        val target = toAbs(audioApiUrlPattern.replace("{url}", pageUrl).replace("{id}", id))
        val headers = mutableMapOf("User-Agent" to UA, "Referer" to pageUrl)
        val resp = throttle.run { fetcher.get(target, headers) }
        val txt = (resp as? FetchOutcome.Ok)?.text?.trim()
        if (txt.isNullOrEmpty() || txt.startsWith("<") || txt.startsWith("Not Found")) return null
        // 响应可能带 BOM 或包在 JSON 里：{"url":"..."} 也要能吃
        val clean = txt.trimStart().trim('"')
        val candidate = if (clean.startsWith("http")) clean
        else URL_RE.find(txt)?.value ?: return null
        if (!AUDIO_EXT.containsMatchIn(candidate)) {
            throw SourceErrors.ParseFailed("播放接口没返回地址：" + txt.take(80))
        }
        return ExtractedAudio(candidate, AudioUrlHeaders.headersFor(candidate), 0L)
    }

    /**
     * ting15 式播放接口：
     *   POST /?s=api-getneoplay  form: bookId=<meta _b>&isPay=<meta _p>&page=<meta _cp>
     *   headers: xt=<meta _c>, l=<meta _l>, Referer=播放页
     *   响应 {"url":"https://.../0001.m4a","status":1}
     * 拿到的是带过期参数的直链，返回后直接播。
     */
    private suspend fun audioFromApi(pageUrl: String): ExtractedAudio? {
        val html = getText(pageUrl, base) ?: return null
        val meta = { n: String ->
            Regex("<meta\\s+name=[\"']" + n + "[\"']\\s+content=[\"']([^\"']*)[\"']", RegexOption.IGNORE_CASE)
                .find(html)?.groupValues?.get(1)
                ?: Regex("<meta\\s+content=[\"']([^\"']*)[\"']\\s+name=[\"']" + n + "[\"']", RegexOption.IGNORE_CASE)
                    .find(html)?.groupValues?.get(1)
        }
        val bookId = meta("_b") ?: return null
        val page = meta("_cp") ?: "1"
        val headers = mutableMapOf(
            "User-Agent" to UA,
            "Referer" to pageUrl,
            "X-Requested-With" to "XMLHttpRequest",
        )
        meta("_c")?.let { headers["xt"] = it }
        meta("_l")?.let { headers["l"] = it }
        val form = mapOf("bookId" to bookId, "isPay" to (meta("_p") ?: "0"), "page" to page)
        val resp = throttle.run { fetcher.post(toAbs(audioApiPattern), headers, form) }
        val txt = (resp as? FetchOutcome.Ok)?.text ?: return null
        val obj = runCatching { Json.parseToJsonElement(txt.trimStart('\uFEFF')).jsonObject }.getOrNull() ?: return null
        val st = str(obj, "status")
        if (st == "-1" || st == "0") throw SourceErrors.Auth("本章需要购买或不存在（status=" + st + "）")
        val u = (str(obj, "url")?.takeIf { it.isNotBlank() } ?: str(obj, "ourl")?.takeIf { it.isNotBlank() })
            ?: throw SourceErrors.ParseFailed("播放接口没返回地址")
        val abs = toAbs(u)
        return ExtractedAudio(abs, AudioUrlHeaders.headersFor(abs), 0L)
    }

    private suspend fun getText(target: String, referer: String): String? {
        val headers = mutableMapOf("User-Agent" to UA)
        if (referer.isNotEmpty()) headers["Referer"] = referer
        val resp = throttle.run { fetcher.get(target, headers) }
        return (resp as? FetchOutcome.Ok)?.text?.takeIf { it.isNotEmpty() }
    }

    /**
     * 相对路径 → 绝对路径。四种形态：
     *   http(s)://  原样返回
     *   //host/path → https://host/path
     *   /path        → base + /path
     *   ?query       → base + /?query（不能变成 base?query，否则吐到页面上的链接会丢 path）
     *   path         → base + /path
     */
    /** 相对地址按"当前页" resolved（url + ?query 时取 url 的目录） */
    private fun resolve(pageUrl: String, href: String): String {
        val h = href.trim()
        if (h.startsWith("http")) return h
        if (h.startsWith("?")) return pageUrl.substringBefore("?") + h
        val host = pageUrl.substringAfter("://").substringBefore("/")
        return if (h.startsWith("/")) "https://" + host + h else pageUrl.substringBeforeLast("/") + "/" + h
    }

    private fun toAbs(href: String): String {
        val h = href.trim()
        return when {
            h.isEmpty() -> base.trimEnd('/')
            h.startsWith("http://") || h.startsWith("https://") -> h
            // P1-4：协议相对地址（//cdn.com/...）不能一律强制 https。
            // 有的 CDN 只支持 http（如 aj006 的音频站），强转会 404。
            // 按 base 的协议继承：base 是 http 就用 http，是 https 就用 https。
            h.startsWith("//") -> {
                val scheme = if (base.startsWith("http://")) "http:" else "https:"
                scheme + h
            }
            h.startsWith("?") -> base.trimEnd('/') + "/" + h
            h.startsWith("/") -> base.trimEnd('/') + h
            else -> base.trimEnd('/') + "/" + h
        }
    }

    /** HTML 实体还原。&amp; 必须最后换：先换成 & 会把 &amp;#038; 二次解码成 & */
    private fun unescape(s: String): String = s
        .replace("&nbsp;", " ")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")

    /** JSON 取值：null / 数组 / 对象一律返回 null，数字与字符串都当字符串用 */
    private fun str(o: JsonObject, key: String): String? {
        if (key.isEmpty()) return null
        val e: JsonElement = o[key] ?: return null
        if (e is JsonArray || e is JsonObject) return null
        val p = e as? JsonPrimitive ?: return null
        if (p.content == "null") return null
        return p.content
    }

    /** 支持 data.programs / 直接是数组 / data.list 三种壳 */
    private fun listAt(root: JsonObject, key: String): JsonArray? {
        // 逐段往下走：data.programs 先入 data 再取 programs（旧实现每次都从 root 取，第二段永远拿不到）
        var cur: JsonObject = root
        val segs = key.split(".").filter { it.isNotEmpty() }
        for (i in segs.indices) {
            val e = cur[segs[i]] ?: break
            if (e is JsonArray) return e
            if (e is JsonObject && i == segs.size - 1) {
                return e.values.filterIsInstance<JsonArray>().firstOrNull()
            }
            cur = e as? JsonObject ?: break
        }
        // 兜底：data 里第一个数组字段（不同站字段名不一样）
        val head = root[segs.firstOrNull() ?: ""] as? JsonObject ?: return null
        return head.values.filterIsInstance<JsonArray>().firstOrNull()
    }

    private fun String.tokenLong(): Long = toLongOrNull() ?: 0L

    companion object {
        const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        /** 完本关键词（P1-6）：站长写法五花八门，这些都算完本 */
        private val FINISHED_WORDS = listOf(
            "已完本", "完本", "已完结", "完结", "全集", "全本", "大结局",
            "已完结全本", "completed",
        )

        /** 反向词：出现这些一律判未完本，压过上面的正向命中 */
        private val ONGOING_WORDS = listOf("连载中", "更新中", "未完本", "未完结")

        fun isFinishedHtml(html: String): Boolean {
            val lower = html.lowercase()
            if (ONGOING_WORDS.any { lower.contains(it) }) return false
            return FINISHED_WORDS.any { lower.contains(it) }
        }

        private const val MAX_JSON_PAGES = 40
        private val AUDIO_EXT = Regex("\\.(?:m4a|mp3|m3u8|aac|flac|wav|ogg)(?:\\?[^\\s\"'<>]*)?$", RegexOption.IGNORE_CASE)
        private val GET_SOURCE = Regex("/program/get-source/\\d+")
        /** 任意 http(s) URL（播放接口返回正文里拿地址用） */
        private val URL_RE = Regex("https?://[^\\s\"'<>]+")
        /** vbus 式节目链接：/v/5893 */
        private val PROGRAM_LINK = Regex("^(?:https?://[^/]+)?/v/(\\d+)/?$")
        /** <a ... href="/v/5893" ...>标题</a> */
        private val LINK_HREF = Regex("<a\\s[^>]*href=[\"']([^\"']+)[\"'][^>]*>([^<]{0,80})</a>", RegexOption.IGNORE_CASE)

        private val AUDIO_RE = listOf(
            Regex("https?://[^\\s\"'<>]+?\\.m4a[^\\s\"'<>]*", RegexOption.IGNORE_CASE),
            Regex("https?://[^\\s\"'<>]+?\\.mp3[^\\s\"'<>]*", RegexOption.IGNORE_CASE),
            Regex("https?://[^\\s\"'<>]+?\\.m3u8[^\\s\"'<>]*", RegexOption.IGNORE_CASE),
            Regex("https?://[^\\s\"'<>]+?\\.aac[^\\s\"'<>]*", RegexOption.IGNORE_CASE),
        )
    }
}
