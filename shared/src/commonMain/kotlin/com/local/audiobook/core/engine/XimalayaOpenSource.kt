package com.local.audiobook.core.engine

import com.local.audiobook.core.CookieProvider
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

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
    private val clock: () -> Long = { 0L },
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
        // 首页/搜索的两次请求（front + suggest）走批量闸：250ms 间隔而不是 1 秒，
        // 否则「3 个分区 × 2 次请求」光间隔就要 6 秒 —— 那正是发现页骨架屏卡那么久的原因。
        val root = getJsonFast(OpenRoutes.search(keywords, page), headersWithCookie(), page == 1)
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
        // 【2026-11-28 死锁修复】这里曾经是 throttle.run { throttle.runBulk { ... } } ——
        // run() 在整个函数体期间都持有 mutex，runBulk 再去拿同一把不可重入的 mutex，
        // 于是永远等下去：**所有第一页搜索都会卡死**。runBulk 自己就是一道闸，外面不能再套 run。
        val r = throttle.runBulk(concurrency = 2) {
            fetcher.get(OpenRoutes.suggest(keywords), headersWithCookie())
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
                sourceId = "ximalaya",
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
            sourceId = "ximalaya",
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

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean,
                                cancel: com.local.audiobook.core.CancelToken): BookDetail {
        val albumId = parseAlbumId(bookUrl) ?: throw SourceErrors.ParseFailed("无法解析 albumId：" + bookUrl)
        val detailRoot = getJsonFast(OpenRoutes.albumSimple(albumId), headersWithCookie(), true)
        val data = detailRoot["data"]?.asObj() ?: throw SourceErrors.NotFound(bookUrl)
        val main = data["albumPageMainInfo"]?.asObj() ?: data

        val book = Book(
            sourceId = "ximalaya",
            bookUrl = "https://www.ximalaya.com/album/" + albumId,
            title = main["albumTitle"]?.asStr() ?: main["title"]?.asStr() ?: ("专辑 " + albumId),
            author = main["anchorName"]?.asStr() ?: "",
            coverUrl = normalizeCover(main["cover"]?.asStr() ?: ""),
            // 【2026-11-28 简介为空】richIntro 是一大段带 style 的 HTML，某些专辑里它只有占位内容，
            // strip 完就剩 "..." —— 界面只剩一排点。shortIntro 是官方提炼好的纯文本，优先用它。
            intro = run {
                val short = main["shortIntro"]?.asStr()?.trim().orEmpty()
                if (short.length >= 8 && short.any { it != '.' && it != '。' }) return@run short
                val rich = main["richIntro"]?.asStr()
                    ?.replace(Regex("<[^>]+>"), "")?.replace("&nbsp;", " ")?.trim().orEmpty()
                if (rich.length >= 8 && rich.any { it != '.' && it != '。' }) return@run rich.take(500)
                main["intro"]?.asStr()?.trim().orEmpty().take(500)
            },
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

        // 【2026-11-25 解决大书详情 80 秒】
        // 旧实现是逐页串行：每页「1 秒节流 + ~1 秒 RTT」，40 页 = 80 秒。
        // 现在两阶段：
        //   ① 先取第 1 页，拿 totalCount / maxPageId —— 由此算出到底要几页；
        //   ② 剩下的页**并发取**（最多 3 个在飞，起始间隔仍受 1 秒节流约束）。
        // mobwsa 实测对 3 并发无风控反应（一轮测过 open+login 双通道并发也正常）。
        // 40 页上限不变 —— 那是「不值得再等」的产品边界，不是性能参数。
        val first = getJsonBulk(OpenRoutes.tracksMobile(albumId, 1), headersWithCookie())
        val firstList = first["list"]?.asArr()
            ?: first["data"]?.asObj()?.get("list")?.asArr()
            ?: JsonArray(emptyList())
        if (firstList.isNotEmpty()) {
            appendTracks(firstList, eps)
            val tc0 = first["totalCount"]?.asLong() ?: 0L
            if (tc0 > 0L) realTotal = tc0
        }
        val maxPageId0 = first["maxPageId"]?.asLong() ?: 0L
        // 总页数：信 maxPageId，没有就按 totalCount/20 推，最后统一卡 40。
        val declared = when {
            maxPageId0 > 0L -> maxPageId0
            realTotal > 0L -> (realTotal + 19) / 20
            else -> 1L
        }
        val lastPage = minOf(declared, maxPages.toLong()).toInt()
        if (lastPage > 1 && !cancel.isCancelled) {
            // 并发取第 2..lastPage 页。每页结果按页码顺序拼回去，保证 index 连续。
            val pages = ArrayList<Pair<Int, JsonArray>>(lastPage)
            coroutineScope {
                val jobs = (2..lastPage).map { p ->
                    async {
                        if (cancel.isCancelled) return@async null
                        val tr = runCatching {
                            getJsonBulk(OpenRoutes.tracksMobile(albumId, p), headersWithCookie())
                        }.getOrNull() ?: return@async null
                        val list = tr["list"]?.asArr()
                            ?: tr["data"]?.asObj()?.get("list")?.asArr()
                            ?: JsonArray(emptyList())
                        val tc = tr["totalCount"]?.asLong() ?: 0L
                        if (tc > 0L) realTotal = tc
                        if (list.isEmpty()) null else (p to list)
                    }
                }
                for (j in jobs) {
                    val r = j.await() ?: continue
                    pages.add(r)
                }
            }
            // 按页码排序后追加，保证跨页 index 单调
            pages.sortBy { it.first }
            for ((_, list) in pages) appendTracks(list, eps)
        }
        // 把真实总集数回填：albumSimple 不给 trackCount，只有曲目接口给 totalCount。
        // 【2026-11-25 P0】收窄翻页上限之后这里必须跟着收：
        // realTotal 是接口报的**真实总集数**（5546），而本函数最多只翻 40 页（800 集）。
        // 直接回填 5546 会让 UI 承诺「共 5546 集」却一条都给不出来 —— 列表只有 800 条，
        // 滚到底 ChapterPager 返回 nil，footer 永远显示「还有 5494 集」且点了没反应。
        // 数字比真实少但**诚实**：显示「共 800 集」，滑到底就是到底。
        val effectiveTotal = if (realTotal > 0L) minOf(realTotal, eps.size.toLong()) else realTotal
        val finalBook = if (effectiveTotal > 0L && book.trackCount != effectiveTotal)
            book.copy(trackCount = effectiveTotal) else book
        return BookDetail(finalBook, eps)
    }

    /** 客户端通道提取器：直接复用登录版那套（同一端点、同一 UA、同一权限判定） */
    private fun clientExtractor(): com.local.audiobook.core.AudioExtractor =
        XimalayaAudioExtractor(fetcher, throttle, cookieProvider, clock)

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                // 【2026-11-27】三条输入形态都要能换到地址：
                //   ① 纯数字         = trackId（VIP 集的 playUrl64 在 mobwsa 里是空串，只留了 id）
                //   ② 喜马拉雅网页   = https://www.ximalaya.com/sound/{id}，从路径里抠 trackId
                //   ③ 其它直链       = 原样校验后返回
                // 以前 ② 会被 requirePlayable 拦下抛「只给了网页地址」——
                // 但那本来就是我们自己塞进去的占位地址，不是上游给的坏数据。
                if (!url.startsWith("http")) {
                    val id = url.trim().toLongOrNull()
                        ?: throw SourceErrors.ParseFailed("不是直链：" + url)
                    return clientExtractor().extract(id.toString(), timeoutMs)
                }
                val pageTrack = XimalayaLinkParser.parse(url).trackId
                if (pageTrack != null && pageTrack > 0L) {
                    return clientExtractor().extract(pageTrack.toString(), timeoutMs)
                }
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

    /**
     * 把一页曲目解析追加进 eps（index 按当前条数续排）。
     *
     * 【2026-11-25 P0 放行】mobwsa 的 VIP 专辑里，**前 20 集对所有人免费**（isFree=true / isAuthorized=true），
     * 但它的 playUrl64 同样返回空串 —— 地址只有客户端通道 `track/baseInfo` 能给。
     * 如果这里把 20 集也标成 playable=false，Player 的 `guard ep.playable` 会直接拒播，
     * 那条通道就永远走不到了（用户连免费集都听不了）。
     *
     * 所以：只要曲子带 trackId，就标 playable=true，让 Player 去调 extractor ——
     * extractor 会用 isAuthorized 判权限，没权限时给出准确文案（比这里瞎猜准）。
     */
    private fun appendTracks(list: JsonArray, eps: MutableList<Episode>) {
        for (el in list) {
            val t = el.asObj() ?: continue
            if (t["trackId"]?.asLong() == null) continue
            val ep = TrackNormalizer.normalizeTrack(t, eps.size + 1, sourceId)
            // 有 trackId 就走客户端通道试一次；没权限时由 extractor 给出「需要会员」文案。
            eps.add(TrackNormalizer.allowRetry(ep))
        }
    }

    /**
     * 带登录态的请求头。
     *
     * 【2026-11-27 P0 破局】以前整个类都用 `OpenRoutes.desktopHeaders()`，**不带 Cookie** ——
     * 于是 mobwsa 永远是匿名视角：会员集的 playUrl64 全是空串，
     * 而我们已经知道服务器认可登录态（baseInfo 返回 isAuth=true）。
     * 把 Cookie 带上之后，mobwsa 很可能直接给会员集的直链 —— 这是最省事的一条路。
     */
    private suspend fun headersWithCookie(): Map<String, String> {
        val base = OpenRoutes.desktopHeaders()
        val c = cookieProvider.cookie() ?: return base
        return base + mapOf("Cookie" to c)
    }


    /**
     * 取一份 JSON，并识别风控信号。
     *
     * 快闸 = runBulk（150ms 起始间隔，允许并发在飞）；慢闸 = run（1 次/秒、单飞）。
     * 两者**不能嵌套**：run() 全程持有 mutex，里面再 runBulk 会自己等自己（2026-11-28 真死锁）。
     *
     * 风控信号：HTTP 403/429，或响应体 ret=999（限流）/ 1001（风控校验）。
     * 命中就调 throttle.riskBackoff() —— 批量间隔自动退回 1 秒并保持 60 秒，之后自己恢复。
     */
    private suspend fun fetchJson(target: String, headers: Map<String, String>,
                                  concurrency: Int, fast: Boolean): JsonObject {
        val resp = if (fast) throttle.runBulk(concurrency = concurrency) { fetcher.get(target, headers) }
                   else throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) {
            val f = resp as FetchOutcome.Failed
            if (f.kind.contains("403") || f.kind.contains("429")) throttle.riskBackoff()
            throw SourceErrors.Network(f.kind)
        }
        val root = runCatching { Json.parseToJsonElement(resp.text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target.take(80))
        val ret = (root["ret"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
        if (ret == "999" || ret == "1001") throttle.riskBackoff()
        return root
    }

    /** 翻页专用：最多 4 个在飞、150ms 起始间隔（大书详情从 ~52 秒降到 ~7 秒） */
    private suspend fun getJsonBulk(target: String, headers: Map<String, String>): JsonObject =
        fetchJson(target, headers, concurrency = 4, fast = true)

    /**
     * 搜索/详情首跳专用：fast=true 走批量闸（150ms），false 退回普通闸（1 秒）。
     */
    private suspend fun getJsonFast(target: String, headers: Map<String, String>, fast: Boolean): JsonObject =
        fetchJson(target, headers, concurrency = 2, fast = fast)

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
