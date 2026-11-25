package com.local.audiobook.core.engine

import com.local.audiobook.core.*
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.ErrorClassifier
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.data.ximalaya.XimalayaLinkParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonArray
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
    // 【P0 v1.4.7】默认值原来是历史 UUID（a6f3c1de-...）。TingshuApp 构造时没传 sourceId，
    // 于是 Book.sourceId 全变成 UUID；而 SourceRegistry.audio(sourceId:) 只认 "ximalaya" 这类短 id，
    // UUID 落到 unknownSource，表现就是「登录后搜出来的书全都播不了」。
    // 改成 "ximalaya"，与 Registry 的 key 一致；显式传参的调用方不受影响。
    override val sourceId: String = "ximalaya",
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

        // 【免登录直链优先】mobwsa 曲目接口直接返回 playUrl64/playUrl32，
        // Episode.url 就是能播的 mp3，而且它**不需要登录态**。
        //
        // v1.4.9 审计 P0：旧实现先拉登录版详情、再拉 mobwsa 曲目。
        // 于是登录版详情一挂（风控/500/会员专辑）就**直接 throw**，
        // 免登录那条根本没机会跑 —— 这就是「搜到了却听不了」的一条路径。
        // 现在正序反过来：mobwsa 先试，它成功就不再依赖登录版；失败才回退。
        val open = fetchOpenAlbum(albumId, loadFullPages)
        val book: Book
        val openEpisodes: List<Episode>?
        if (open != null) {
            book = open.book
            openEpisodes = open.episodes
        } else {
            // 回退：登录版详情（page=1&pageSize=1，bridge 同款）
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
            book = AlbumNormalizer.normalizeAlbum(albumRaw, sourceId)
            openEpisodes = null
        }

        if (!loadEpisodes) return BookDetail(book, emptyList())
        if (openEpisodes != null) return BookDetail(book, openEpisodes)

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
    /** 免登录拿到的整本：专辑信息 + 带直链的曲目（曲目里的 album 字段就能拼出 Book） */
    private data class OpenAlbum(val book: Book, val episodes: List<Episode>)

    /**
     * 免登录拿专辑 + 曲目。
     * mobwsa 的响应里每条曲目都带 albumId/albumTitle/albumCover/albumUserNickName，
     * 所以不用另外再拉一次登录版详情 —— 登录版详情挂了也不影响能播。
     */
    private suspend fun fetchOpenAlbum(albumId: Long, loadFullPages: Boolean): OpenAlbum? {
        // 【v1.4.9】以前这里传的是「40 页」常数 —— 1327 集的专辑只拿前 800 集，
        // 剩下的永远缺。又没有去重，分页参数写错时同一页会被 addAll 40 次。
        // 现在：先探 1 页拿 totalCount，再算需要几页。
        val first = fetchOpenTracks(albumId, 1, collectAlbum = true)
        if (first.episodes.isEmpty()) return null
        val total = first.totalCount
        val needPages = if (loadFullPages && total > 0) {
            minOf(((total + 19) / 20).toInt() + 1, 200)
        } else 1
        val tracks = if (needPages <= 1) first
            else fetchOpenTracks(albumId, needPages, collectAlbum = true)
        if (tracks.episodes.isEmpty()) return null
        val albumObj = tracks.albumJson
            ?: JsonObject(mapOf("albumId" to kotlinx.serialization.json.JsonPrimitive(albumId)))
        return OpenAlbum(AlbumNormalizer.normalizeAlbum(albumObj, sourceId), tracks.episodes)
    }

    private class OpenTracks(val episodes: List<Episode>, val albumJson: JsonObject?, val totalCount: Long = 0L)

    private suspend fun fetchOpenTracks(albumId: Long, maxPages: Int, collectAlbum: Boolean = true): OpenTracks {
        if (maxPages <= 0) return OpenTracks(emptyList(), null)
        val out = ArrayList<Episode>()
        var albumJson: JsonObject? = null
        var totalCount = 0L
        var page = 1
        while (page <= minOf(maxPages, 200)) {
            val url = OpenRoutes.tracksMobile(albumId, page, 20)
            val resp = runCatching { throttle.run { fetcher.get(url, OpenRoutes.desktopHeaders()) } }.getOrNull()
            // 任何一页失败（网络/403/非 JSON）都只能「停下来」，**不能把已经拿到的页丢掉**：
            // 旧实现用 break（保留），但第一页返回「没有直链」时 return emptyList() 是对的（确实不适用）。
            // 这里把两种情况分开：拿到过就保留，一页没拿到才说「不适用」。
            val ok = resp as? FetchOutcome.Ok ?: break
            val json = parse(ok.text) ?: break
            val tp = TrackExtractor.fromOpenList(json, page, 20, sourceId)
            if (tp.episodes.isEmpty()) break
            // 第一页就一条直链都没有 → 这个接口对该专辑不适用（登录版专辑常见）
            if (out.isEmpty() && tp.episodes.none { AudioUrlHeaders.isPlayableAudio(it.url) }) {
                return OpenTracks(emptyList(), null)
            }
            if (albumJson == null && collectAlbum) {
                albumJson = firstAlbumObject(json)
            }
            // 按 trackId 去重：分页参数一旦被服务端忽略，同一页会被反复返回，
            // 不判重的话 out 会膨胀成「同一集 × N 次」。
            val seen = out.mapTo(HashSet()) { it.trackId }
            for (e in tp.episodes) if (seen.add(e.trackId)) out.add(e)
            totalCount = tp.totalCount
            if (tp.episodes.size < 20) break
            if (tp.totalCount > 0 && out.size >= tp.totalCount) break
            page++
        }
        return OpenTracks(out, albumJson, totalCount)
    }

    /** mobwsa 响应里的首条 album 子对象（拿来当 Book 的源） */
    private fun firstAlbumObject(root: JsonObject): JsonObject? {
        val list = (root["list"] as? JsonArray) ?: return null
        val first = list.firstOrNull() as? JsonObject ?: return null
        // 先看有没有直接的 album 对象；没有就用曲目里拼
        (first["album"] as? JsonObject)?.let { return it }
        val built = mutableMapOf<String, kotlinx.serialization.json.JsonElement>()
        listOf(
            "albumId" to listOf("albumId"),
            "title" to listOf("albumTitle", "albumName"),
            "cover" to listOf("albumCover", "coverLarge", "coverMiddle", "coverSmall"),
            "nickname" to listOf("albumUserNickName", "nickname"),
            "intro" to listOf("albumIntro"),
        ).forEach { (target, sources) ->
            for (s in sources) {
                val v = first[s]
                if (v != null && v !is kotlinx.serialization.json.JsonNull) { built[target] = v; break }
            }
        }
        return if (built.isEmpty()) null else JsonObject(built)
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
