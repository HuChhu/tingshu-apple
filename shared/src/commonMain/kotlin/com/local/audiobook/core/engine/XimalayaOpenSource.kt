package com.local.audiobook.core.engine

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
        val books = docs.mapNotNull { d -> d.asObj()?.let { docToBook(it) } }
        val maxPage = if (books.size >= 20) page + 1 else page
        return SearchResult(
            books = books,
            maxPage = maxPage,
            source = sourceId,
            page = page,
            hint = if (books.isEmpty()) "喜马拉雅没搜到这本书" else null,
        )
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
        val maxPages = if (loadFullPages) 60 else 1
        while (pg <= maxPages) {
            val tr = getJson(OpenRoutes.tracksMobile(albumId, pg), OpenRoutes.desktopHeaders())
            val list = tr["list"]?.asArr()
                ?: tr["data"]?.asObj()?.get("list")?.asArr()
                ?: JsonArray(emptyList())
            if (list.isEmpty()) break
            for (el in list) {
                val t = el.asObj() ?: continue
                val trackId = t["trackId"]?.asLong() ?: continue
                val direct = t["playUrl64"]?.asStr() ?: t["playUrl32"]?.asStr()
                eps.add(Episode(
                    title = t["title"]?.asStr() ?: ("第" + (eps.size + 1) + "集"),
                    url = direct ?: ("https://www.ximalaya.com/sound/" + trackId),
                    trackId = trackId,
                    index = eps.size + 1,
                    durationMs = (t["duration"]?.asLong() ?: 0L) * 1000,
                    coverUrl = normalizeCover(t["coverLarge"]?.asStr() ?: ""),
                ))
            }
            val maxPageId = tr["maxPageId"]?.asLong() ?: 0L
            if (maxPageId in 1L..pg.toLong()) break
            pg++
        }
        return BookDetail(book, eps)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                if (!url.startsWith("http")) throw SourceErrors.ParseFailed("不是直链：" + url)
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
