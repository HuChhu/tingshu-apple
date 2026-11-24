package com.local.audiobook.core.engine

import com.local.audiobook.core.*
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.ErrorClassifier
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.data.ximalaya.XimalayaLinkParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

// 三动作编排。行为基线 = bridge api.py：
// search：先移动端、失败不硬冲、网页端点受预算闸门、降级给 hint（M1 已验收）
// bookDetail：详情+曲目双请求、索引数学、normalize_track 回退链、专辑不存在→NotFound（M2）
// audioExtractor：级1→级3 播放地址提取（M2）
class SearchEngine(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    private val budget: WebSearchBudget,
    private val nowMs: () -> Long = { 0L },
    private val cookieProvider: CookieProvider = object : CookieProvider {
        override suspend fun cookie(): String? = null
        override suspend fun refresh() {}
    },
    override val sourceId: String = "a6f3c1de-2b47-4e8a-9c05-7d1b44f0e9a2",
) : SourceActions {

    override val url = SearchRoutes.WEB_BASE
    override val name = "喜马拉雅"
    override val desc = "官方接口直连，风控不硬冲，搜索降级给提示"
    override val capabilities = Capabilities(searchable = true, discoverable = true, cacheable = true, needsWebView = false)

    private val extractor = XimalayaAudioExtractor(fetcher, throttle, cookieProvider)
    override fun audioExtractor(): AudioExtractor = extractor

    private fun parse(text: String): JsonObject? =
        runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()

    private fun headersOf(ua: String, referer: String) = mapOf(
        "User-Agent" to ua,
        "Accept" to "application/json, text/plain, */*",
        "Referer" to referer,
    )

    private suspend fun withCookie(headers: Map<String, String>): Map<String, String> {
        val c = cookieProvider.cookie() ?: return headers
        return headers + mapOf("Cookie" to c)
    }

    private fun inferMaxPage(books: Int, page: Int) = if (books >= 20) page + 1 else page

    private fun degraded(page: Int, reason: String) = SearchResult(
        books = emptyList(), maxPage = 0, source = "none", page = page,
        hint = reason + "；搜索降级：在喜马拉雅 App 内搜索后，复制分享链接或专辑 ID 到 App 直达",
    )

    // albumId 解析统一走 XimalayaLinkParser（禁双实现漂移）：/album/{id}、?albumId=、纯数字（≥4位）
    fun parseAlbumId(bookUrl: String): Long? = XimalayaLinkParser.parse(bookUrl).albumId

    // ---------- 动作一：search（M1 已验收，行为不变） ----------
    override suspend fun search(keywords: String, page: Int): SearchResult {
        // 【实机修复 2026-11-24】第一路原来是 mobile.ximalaya.com 的
        // mobile-search-search-words-mobile：实测该端点已废，稳定返回 HTML 小站页
        // （"Search 的小站"），每次搜索都白跑一次还被算进限速。
        // 直接换成 search.ximalaya.com/front/v1 —— 同一个搜索核心，
        // 刚实测 200 + 38KB JSON，风控（riskLevel=5）只拦网页 revision 接口，不拦这个。
        val front = throttle.run {
            fetcher.get(OpenRoutes.search(keywords, page), OpenRoutes.desktopHeaders())
        }
        if (front is FetchOutcome.Ok) {
            val fj = parse(front.text)
            val books = AlbumExtractor.fromSearchFront(fj, sourceId)
            if (books.isNotEmpty()) {
                return SearchResult(books, inferMaxPage(books.size, page), "front", page)
            }
        }

        val (allowed, why) = budget.canAttempt()
        if (!allowed) return degraded(page, "预算拦截：" + why)

        val web = throttle.run {
            fetcher.get(SearchRoutes.webSearch(keywords, page, 20), headersOf(SearchRoutes.WEB_UA, SearchRoutes.WEB_BASE + "/"))
        }
        if (web !is FetchOutcome.Ok) {
            web as FetchOutcome.Failed
            budget.record(null, web.kind, false)
            return degraded(page, "网页搜索失败（网络层：" + web.kind + "）")
        }
        val wjson = parse(web.text)
        if (wjson == null) {
            budget.record(null, "非JSON响应", false)
            return degraded(page, "网页搜索失败（响应非JSON）")
        }
        val (status, err) = ErrorClassifier.classifyJson(web.httpStatus, wjson)
        val inner = wjson["data"] as? JsonObject
        val riskLevel = inner?.get("riskLevel")?.let { runCatching { it.jsonPrimitivePrimitive() }.getOrNull() }
        val reason = inner?.get("reason")?.let { runCatching { it.jsonPrimitiveContent() }.getOrNull() } ?: ""
        budget.record(riskLevel, reason, status == "ok")
        if (status != "ok") {
            val errName = err?.let { it::class.simpleName } ?: "未知"
            return degraded(page, "网页搜索失败（" + status + ", riskLevel=" + (riskLevel ?: -1) + "）→ " + errName)
        }
        val books = AlbumExtractor.fromWeb(wjson, sourceId)
        if (books.isEmpty()) return degraded(page, "网页搜索解析为空")
        return SearchResult(books, inferMaxPage(books.size, page), "web", page)
    }

    // ---------- 动作二：bookDetail（M2，bridge get_book_detail 语义对齐） ----------
    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val albumId = parseAlbumId(bookUrl)
            ?: throw SourceErrors.ParseFailed("无法从 bookUrl 解析 albumId：" + bookUrl)

        val headers = withCookie(headersOf(SearchRoutes.MOBILE_UA, "https://m.ximalaya.com/"))

        // 详情页（page=1&pageSize=1，bridge 同款）
        val detailResp = throttle.run { fetcher.get(DetailRoutes.albumPage(albumId, 1, 1, nowMs()), headers) }
        if (detailResp !is FetchOutcome.Ok) throw SourceErrors.Network((detailResp as FetchOutcome.Failed).kind)
        val djson = parse(detailResp.text) ?: throw SourceErrors.ParseFailed("详情响应非JSON")
        val (dstatus, derr) = ErrorClassifier.classifyJson((detailResp as FetchOutcome.Ok).httpStatus, djson)
        if (dstatus == "need_login") {
            cookieProvider.refresh()   // 一次；不重试（不硬冲）
            throw derr ?: SourceErrors.Auth("需要登录")
        }
        if (dstatus != "ok") throw derr ?: SourceErrors.ParseFailed("详情分类异常：" + dstatus)

        val albumRaw = (djson["data"] as? JsonObject)?.get("album") as? JsonObject
            ?: throw SourceErrors.NotFound(bookUrl)   // 对齐 bridge「专辑不存在或已下架」
        val book = AlbumNormalizer.normalizeAlbum(albumRaw, sourceId)

        if (!loadEpisodes) return BookDetail(book, emptyList())

        // 【优先免登录直链】免登录的 mobwsa 曲目接口直接返回 playUrl64/playUrl32，
        // Episode.url 就是能播的 mp3，不用再走登录版 + 网页地址那一套。
        // 真机 2026-11-24：登录版只给 trackId，脱障后 Episode.url = /sound/{id} 网页 → AVPlayer -12847。
        run {
            val direct = fetchOpenTracks(albumId, if (loadFullPages) maxOf(book.trackCount, 40L).toInt() else 1)
            if (direct.isNotEmpty()) return BookDetail(book, direct)
        }

        // 曲目（惰性：loadEpisodes=true 才拉；loadFullPages=true 翻完）
        // 翻页收口三重闸：totalCount（信封实录）→ book.trackCount → maxPageId/硬上限 200
        val pageSize = 30
        val episodes = ArrayList<Episode>()
        var page = 1
        var totalCount = 0L
        var maxPageId = 0L
        while (true) {
            val resp = throttle.run { fetcher.get(DetailRoutes.albumPage(albumId, page, pageSize, nowMs()), headers) }
            if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
            val tjson = parse(resp.text) ?: throw SourceErrors.ParseFailed("曲目响应非JSON（page=" + page + "）")
            val (tstatus, terr) = ErrorClassifier.classifyJson(resp.httpStatus, tjson)
            if (tstatus == "need_login") {
                cookieProvider.refresh()
                throw terr ?: SourceErrors.Auth("需要登录")
            }
            if (tstatus != "ok") throw terr ?: SourceErrors.ParseFailed("曲目分类异常（page=" + page + "）")

            val tp = TrackExtractor.fromDetail(tjson["data"] as? JsonObject ?: JsonObject(emptyMap()), page, pageSize, sourceId)
            if (tp.episodes.isEmpty()) break
            episodes.addAll(tp.episodes)
            totalCount = tp.totalCount
            maxPageId = tp.maxPageId
            if (!loadFullPages) break
            if (totalCount > 0 && episodes.size >= totalCount) break
            if (book.trackCount > 0 && episodes.size >= book.trackCount) break
            if (page >= maxOf(maxPageId, 200L).toInt()) break
            page++
        }
        return BookDetail(book, episodes)
    }

    /**
     * 免登录曲目：mobwsa 一页 20 条，带 playUrl64 直链。
     * maxPages 控制拉多少页（0 = 不拉）；失败返回空，让调用方退回登录版路径。
     *
     * 不占用登录版的 WebSearchBudget（那是搜索预算，这里是详情）。
     */
    private suspend fun fetchOpenTracks(albumId: Long, maxPages: Int): List<Episode> {
        if (maxPages <= 0) return emptyList()
        val out = ArrayList<Episode>()
        var page = 1
        while (page <= minOf(maxPages, 200)) {
            val url = OpenRoutes.tracksMobile(albumId, page, 20)
            val resp = throttle.run { fetcher.get(url, OpenRoutes.desktopHeaders()) }
            if (resp !is FetchOutcome.Ok) break
            val json = parse(resp.text) ?: break
            val tp = TrackExtractor.fromOpenList(json, page, 20, sourceId)
            if (tp.episodes.isEmpty()) break
            // 一条直链都没有 → 这个接口对该专辑不适用，整体放弃（避免拼出半成品）
            if (out.isEmpty() && tp.episodes.none { AudioUrlHeaders.isPlayableAudio(it.url) }) return emptyList()
            out.addAll(tp.episodes)
            if (tp.episodes.size < 20) break
            if (tp.totalCount > 0 && out.size >= tp.totalCount) break
            page++
        }
        return out
    }

    // ---------- 发现：类目热榜（M1，匿名） ----------
    suspend fun discover(categoryId: Long = 3, pageNum: Int = 1, pageSize: Int = 12): SearchResult {
        val resp = throttle.run {
            fetcher.get(SearchRoutes.categoryAlbums(categoryId, pageNum, pageSize), headersOf(SearchRoutes.WEB_UA, SearchRoutes.WEB_BASE + "/"))
        }
        if (resp !is FetchOutcome.Ok) {
            resp as FetchOutcome.Failed
            return SearchResult(emptyList(), 0, "none", pageNum, "网络层失败：" + resp.kind)
        }
        val json = parse(resp.text) ?: return SearchResult(emptyList(), 0, "none", pageNum, "响应非JSON")
        val (status, err) = ErrorClassifier.classifyJson(resp.httpStatus, json)
        if (status != "ok") {
            return SearchResult(emptyList(), 0, "none", pageNum, "类目接口异常：" + status + " " + (err?.toString() ?: ""))
        }
        val books = AlbumExtractor.fromCategory(json, sourceId)
        val total = (json["data"] as? JsonObject)?.get("total")?.let { runCatching { it.jsonPrimitiveContent().toLongOrNull() }.getOrNull() } ?: 0L
        val maxPage = when {
            pageSize > 0 && total > 0 -> ((total + pageSize - 1) / pageSize).toInt()
            books.isNotEmpty() -> pageNum + 1
            else -> 0
        }
        return SearchResult(books, maxPage, "category", pageNum)
    }
}

// JSON 元素取值的小工具（engine 内部专用）
internal fun kotlinx.serialization.json.JsonElement.jsonPrimitiveContent(): String =
    (this as? kotlinx.serialization.json.JsonPrimitive)?.content ?: toString()

internal fun kotlinx.serialization.json.JsonElement.jsonPrimitivePrimitive(): Int? =
    (this as? kotlinx.serialization.json.JsonPrimitive)?.content?.trim()?.toIntOrNull()
