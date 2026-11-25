package com.local.audiobook.core.engine

import com.local.audiobook.core.CookieProvider

import com.local.audiobook.core.Book
import com.local.audiobook.core.BookDetail
import com.local.audiobook.core.Capabilities
import com.local.audiobook.core.Episode
import com.local.audiobook.core.ExtractedAudio
import com.local.audiobook.core.SourceActions
import com.local.audiobook.core.SearchResult
import com.local.audiobook.core.SourceErrors
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.data.ximalaya.XimalayaLinkParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * 喜马拉雅免登录源
 *
 * 【来源】反编译 sources_by_agg.jar 的 XimalayaLogin，发现源作者的绕法：
 *   搜索用 search.ximalaya.com/front/v1（不是 revision/search）
 *   曲目用 mobwsa/mobile/playlist/album/page（不是 revision/getTracksList）
 *   后者直接返回 playUrl64 / playUrl32 直链
 *
 * 【实测 2026-11-23】全部 200，不需要登录、webtk、极验
 */
class XimalayaOpenSource(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    /** 有 Cookie 说明用户已登录：官方主推那张要交给登录通道，否则 VIP 集永远拿不到地址 */
    private val cookieProvider: CookieProvider = object : CookieProvider {
        override suspend fun cookie(): String? = null
        override suspend fun refresh() {}
    },
    override val sourceId: String = "ximalaya-open",
    override val name: String = "喜马拉雅（免登录）",
) : SourceActions {

    override val url = "https://www.ximalaya.com"
    override val desc = "官方公开接口直连，免登录，不需要过验证码"
    override val capabilities = Capabilities(
        searchable = true,
        discoverable = true,
        cacheable = false,
        needsWebView = false,
        searchVerifiable = false,
        needsLogin = false,
        multipleEpisodePages = true,
    )

    override suspend fun search(keywords: String, page: Int): SearchResult {
        val root = getJson(OpenRoutes.search(keywords, page), OpenRoutes.desktopHeaders())
        val docs = root["response"]?.asObj()?.get("docs")?.asArr() ?: JsonArray(emptyList())
        val books = docs.mapNotNull { d -> d.asObj()?.let { docToBook(it) } }.toMutableList()

        // 主搜之外再打一次 suggest。两个是**不同的池子**：
        //   front/v1 是网页搜索池（免费优先，VIP 专辑压根不进结果）；
        //   suggest 是官方运营联想池（每个词 1 条，但给的是官方主推那张）。
        // 只在第一页补，按 albumId 去重；补在最前面，因为它是「用户心里的第一名」。
        if (page <= 1) {
            val official = fetchOfficialPick(keywords)
            if (official != null && books.none { it.albumId == official.albumId }) {
                books.add(0, official)
            }
        }

        val maxPage = if (books.size >= 20) page + 1 else page
        return SearchResult(
            books = books,
            maxPage = maxPage,
            source = sourceId,
            page = page,
            hint = if (books.isEmpty()) "喜马拉雅没搜到这本书" else null,
        )
    }

    /**
     * 官方主推那一张。失败一律返回 null —— 搜索不能因为补一条而整体失败。
     * 只取 albumResultList 第一条，它是官方运营挑过的，正好就是官方 App 里的第一名。
     */
    /** 当前有没有登录 Cookie（决定 suggest 补的那条该交给哪个通道） */
    private suspend fun hasLoginCookie(): Boolean =
        !cookieProvider.cookie().isNullOrBlank()

    private suspend fun fetchOfficialPick(keywords: String): Book? = try {
        val r = throttle.run {
            fetcher.get(OpenRoutes.suggest(keywords), OpenRoutes.desktopHeaders())
        }
        val ok = (r as? FetchOutcome.Ok)?.text
        if (ok.isNullOrBlank()) null
        else {
            val j = Json.parseToJsonElement(ok).asObj() ?: return null
            val first = j["albumResultList"]?.asArr()?.firstOrNull()?.asObj()
            val id = first?.get("id")?.asLong() ?: 0L
            val kw = first?.get("keyword")?.asStr() ?: ""
            if (id <= 0L || kw.isBlank()) null
            else Book(
                // 【2026-11-25 P0】suggest 补的这条以前硬编码成当前源（= ximalaya-open）。
                // 官方主推的往往是 VIP 专辑，而 VIP 集的直链只有登录通道能换到；
                // 免登录通道对 VIP 集永远返回空 playUrl。
                // 于是登录用户点进来也全是锁 —— 不是会员没生效，是我们把他推到了错的那条路。
                // 现在按登录态给源：有 Cookie 就给登录通道，没有才给免登录。
                sourceId = if (hasLoginCookie()) "ximalaya" else sourceId,
                bookUrl = "https://www.ximalaya.com/album/" + id,
                title = kw,
                author = "",
                coverUrl = normalizeCover(first?.get("imgPath")?.asStr() ?: ""),
                intro = "",
                albumId = id,
                trackCount = 0L,
                playCount = 0L,
                isFinished = null,
            )
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        null
    }

    private fun docToBook(o: JsonObject): Book? {
        val id = o["id"]?.asStr()?.toLongOrNull() ?: return null
        val title = o["title"]?.asStr()?.takeIf { it.isNotBlank() } ?: return null
        return Book(
            sourceId = sourceId,
            bookUrl = "https://www.ximalaya.com/album/" + id,
            title = title,
            author = o["nickname"]?.asStr() ?: o["anchorName"]?.asStr() ?: "",
            coverUrl = normalizeCover(o["cover_path"]?.asStr() ?: o["coverPath"]?.asStr() ?: ""),
            intro = o["intro"]?.asStr()?.take(300) ?: "",
            albumId = id,
            trackCount = o["track_count"]?.asLong() ?: o["trackCount"]?.asLong() ?: 0L,
            playCount = o["play"]?.asLong() ?: 0L,
            isFinished = (o["is_finished"]?.asStr() == "1") || (o["isFinished"]?.asStr() == "1"),
        )
    }

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val albumId = parseAlbumId(bookUrl) ?: throw SourceErrors.ParseFailed("无法解析 albumId：" + bookUrl)
        val detailRoot = getJson(OpenRoutes.albumSimple(albumId), OpenRoutes.desktopHeaders())
        val data = detailRoot["data"]?.asObj() ?: throw SourceErrors.NotFound(bookUrl)
        val main = data["albumPageMainInfo"]?.asObj() ?: data

        val book = Book(
            sourceId = sourceId,
            bookUrl = "https://www.ximalaya.com/album/" + albumId,
            title = main["albumTitle"]?.asStr() ?: main["title"]?.asStr() ?: ("专辑 " + albumId),
            author = main["anchorName"]?.asStr() ?: "",
            coverUrl = normalizeCover(main["cover"]?.asStr() ?: ""),
            intro = main["richIntro"]?.asStr()?.replace(Regex("<[^>]+>"), "")?.take(500) ?: "",
            albumId = albumId,
            trackCount = main["trackCount"]?.asLong() ?: 0L,
            playCount = main["playCount"]?.asLong() ?: 0L,
            isFinished = main["isFinished"]?.asStr() == "true" || main["isFinished"]?.asStr() == "1",
        )

        if (!loadEpisodes) return BookDetail(book, emptyList())

        val eps = mutableListOf<Episode>()
        var pg = 1
        // 【2026-11-25 P0 集数不对】以前写死 60 页上限，且**用书的 trackCount 当总集数**。
        // 实测 albumSimple 根本不返回 trackCount（返回 None），于是 trackCount=0，
        // 界面就退化成拿「已加载条数」当总数 —— 上一版显示 50、20 都是这么来的。
        // 现在：先用第一页的 totalCount 定页数，翻完再把真实条数写回 book.trackCount。
        // 【2026-11-25 实测收窄】以前是 200 页硬上限。实测「大凯故事会」5546 集，
        // 翻到 4000 集要 **5 分钟** —— 详情页转 5 分钟等于不可用，用户早就返回了。
        // 现在按 totalCount 算页数，并且总页数封顶 40（= 800 集），再多的书先给前 800 集，
        // 用户滚到底会触发 loadNextPage（客户端分页），体验上比干等 5 分钟好得多。
        // 另外：一旦拿到 totalCount 就按它算，页面明确结束，不会白跑满上限。
        val maxPages = if (loadFullPages) 40 else 1
        var realTotal = 0L
        while (pg <= maxPages) {
            val tr = getJson(OpenRoutes.tracksMobile(albumId, pg), OpenRoutes.desktopHeaders())
            val list = tr["list"]?.asArr()
                ?: tr["data"]?.asObj()?.get("list")?.asArr()
                ?: JsonArray(emptyList())
            if (list.isEmpty()) break
            for (el in list) {
                val t = el.asObj() ?: continue
                // 【2026-11-25 P0】这里原来是 TrackNormalizer 的第二份手抄版：
                //   val direct = playUrl64 ?: playUrl32      // playUrl64="" 时 asStr 得空串，Elvis 不触发
                //   url = direct ?: ("https://www.ximalaya.com/sound/" + trackId)
                // 两个坑叠在一起：VIP 轨（playUrl64="" 且 playUrl32=""）落成网页地址；
                // 半残轨（64 空、32 有）落成空串。而且没传 playable，默认 true ——
                // 于是「能播不能播」这条信息在推荐页/详情页这条路上彻底丢了。
                // 直接复用 TrackNormalizer，一份逻辑一处维护。
                if (t["trackId"]?.asLong() == null) continue
                eps.add(TrackNormalizer.normalizeTrack(t, eps.size + 1, sourceId))
            }
            val tc = tr["totalCount"]?.asLong() ?: 0L
            if (tc > 0L) realTotal = tc
            val maxPageId = tr["maxPageId"]?.asLong() ?: 0L
            if (maxPageId in 1L..pg.toLong()) break
            pg++
        }
        // 把真实总集数回填：albumSimple 不给 trackCount，只有曲目接口给 totalCount。
        // 不回填的话详情页「共 N 集」永远是 0 / 已加载数。
        // 【2026-11-25 P0】收窄翻页上限之后，这里必须跟着收：
        // realTotal 是接口报的**真实总集数**（5546），而本函数最多只翻 40 页（800 集）。
        // 直接回填 5546 会让 UI 承诺「共 5546 集」然后一条都给不出来：
        // 列表只有 800 条，滚到底 ChapterPager 返回 nil → footer 永远显示「还有 5496 集」且点了没反应。
        // 数字比真实少但**诚实**：显示「共 800 集」，滑到底就是到底。
        val effectiveTotal = if (realTotal > 0L) minOf(realTotal, eps.size.toLong()) else realTotal
        val finalBook = if (effectiveTotal > 0L && book.trackCount != effectiveTotal)
            book.copy(trackCount = effectiveTotal) else book
        return BookDetail(finalBook, eps)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                if (!url.startsWith("http")) throw SourceErrors.ParseFailed("不是直链：" + url)
                // 【P0 2026-11-24】这里原来是把输入原样返回，于是
                // https://www.ximalaya.com/sound/{trackId}（专辑详情阶段 TrackNormalizer 给出的**网页**地址）
                // 被当成音频交给 AVPlayer，报 -12847（kAudioFormatUnsupportedDataFormatError）。
                // 出口必须校验：门户域名/网页后缀一律拦，绝不原样透传。
                AudioUrlHeaders.requirePlayable(url, "喜马拉雅（免登录）")
                return ExtractedAudio(
                    url = url,
                    headers = if (OpenRoutes.isAudioCdn(url)) OpenRoutes.audioHeaders() else emptyMap(),
                    expiresInSeconds = 0L,
                )
            }
        }

    private fun parseAlbumId(bookUrl: String): Long? {
        XimalayaLinkParser.parse(bookUrl).albumId?.let { return it }
        if (bookUrl.all { it.isDigit() }) return bookUrl.toLongOrNull()
        Regex("/album/(\\d+)").find(bookUrl)?.let { return it.groupValues[1].toLongOrNull() }
        return null
    }

    private fun normalizeCover(raw: String): String = when {
        raw.isEmpty() -> ""
        raw.startsWith("//") -> "https:" + raw
        raw.startsWith("http") -> raw
        else -> "https://imagev2.xmcdn.com/" + raw.trimStart(47.toChar())
    }

    private suspend fun getJson(target: String, headers: Map<String, String>): JsonObject {
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return runCatching { Json.parseToJsonElement(resp.text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target.take(80))
    }

    private fun JsonElement.asObj(): JsonObject? = runCatching { jsonObject }.getOrNull()
    private fun JsonElement.asArr(): JsonArray? = runCatching { jsonArray }.getOrNull()
    private fun JsonElement.asStr(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement.asLong(): Long? = (this as? JsonPrimitive)?.content?.toLongOrNull()
}
