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

/**
 * 哔哩哔哩源（免登录）
 *
 * 【来源】反编译 sources_by_agg.jar 的 BiLiBiLi / BiliBili
 * 【实测 2026-11-23】
 *   无 cookie    → 412 风控
 *   伪造 buvid3  → 200，20 条结果
 *   详情 view    → 200，44KB，含 pages[].cid
 *   播放 playurl → 200，41KB，dash.audio 3 条音轨
 *   下载音频     → 1,352,083 字节，ftypiso5（标准 fMP4）
 *
 * 【关键】buvid3 只校验格式（UUID 大写 + infoc 后缀），不校验真实性。
 *   每次随机生成 UUID 就能过风控。
 */
class BilibiliSource(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    override val sourceId: String = "bilibili",
    override val name: String = "哔哩哔哩",
) : SourceActions {

    override val url = "https://www.bilibili.com"
    override val desc = "B站有声书/广播剧，多P视频每P一集，免登录"
    override val capabilities = Capabilities(
        searchable = true, discoverable = true, cacheable = false,
        needsWebView = false, searchVerifiable = false, needsLogin = false,
        multipleEpisodePages = false,
    )

    private val buvid3: String = "buvid3=" + randomUuidUpper() + "infoc"

    private fun randomUuidUpper(): String {
        val hex = "0123456789ABCDEF"
        val sb = StringBuilder()
        for (i in 0 until 32) {
            if (i == 8 || i == 12 || i == 16 || i == 20) sb.append('-')
            sb.append(hex[(0..15).random()])
        }
        return sb.toString()
    }

    override suspend fun search(keywords: String, page: Int): SearchResult {
        val target = "https://api.bilibili.com/x/web-interface/search/type" +
            "?search_type=video&keyword=" + SearchRoutes.enc(keywords) + "&page=" + page
        val root = getJson(target)
        if (root.optInt("code") != 0) {
            return SearchResult(emptyList(), 0, sourceId, page,
                "B站返回：" + (root["message"]?.asStr() ?: "未知错误"))
        }
        val result = root["data"]?.asObj()?.get("result")?.asArr() ?: JsonArray(emptyList())
        val books = result.mapNotNull { el ->
            val o = el.asObj() ?: return@mapNotNull null
            val bvid = o["bvid"]?.asStr() ?: return@mapNotNull null
            val title = (o["title"]?.asStr() ?: "").replace(Regex("<[^>]+>"), "")
            if (title.isBlank()) return@mapNotNull null
            Book(
                sourceId = sourceId,
                bookUrl = "bilibili://video/" + bvid,
                title = title,
                author = o["author"]?.asStr() ?: "",
                coverUrl = normalizeCover(o["pic"]?.asStr() ?: ""),
                intro = o["description"]?.asStr()?.take(300) ?: "",
                albumId = 0L, trackCount = 0L,
                playCount = o["play"]?.optInt()?.toLong() ?: 0L,
                isFinished = false,
            )
        }
        return SearchResult(books, if (books.size >= 20) page + 1 else page, sourceId, page,
            if (books.isEmpty()) "B站没搜到" else null)
    }

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val bvid = bookUrl.substringAfterLast('/')
        if (bvid.isEmpty()) throw SourceErrors.ParseFailed("无法解析 bvid：" + bookUrl)
        val root = getJson("https://api.bilibili.com/x/web-interface/view?bvid=" + bvid)
        if (root.optInt("code") != 0) throw SourceErrors.NotFound(bookUrl)
        val data = root["data"]?.asObj() ?: throw SourceErrors.NotFound(bookUrl)
        val pages = data["pages"]?.asArr() ?: JsonArray(emptyList())

        val book = Book(
            sourceId = sourceId,
            bookUrl = "bilibili://video/" + bvid,
            title = data["title"]?.asStr() ?: "B站视频",
            author = data["owner"]?.asObj()?.get("name")?.asStr() ?: "",
            coverUrl = normalizeCover(data["pic"]?.asStr() ?: ""),
            intro = data["desc"]?.asStr()?.take(500) ?: "",
            albumId = 0L,
            trackCount = pages.size.toLong(),
            playCount = data["stat"]?.asObj()?.get("view")?.optLong() ?: 0L,
            isFinished = false,
        )
        if (!loadEpisodes) return BookDetail(book, emptyList())

        val aid = data["aid"]?.optLong() ?: 0L
        val eps = pages.mapIndexedNotNull { idx, el ->
            val p = el.asObj() ?: return@mapIndexedNotNull null
            val cid = p["cid"]?.optLong() ?: return@mapIndexedNotNull null
            Episode(
                title = p["part"]?.asStr() ?: ("P" + (idx + 1)),
                url = "bilibili://play/" + aid + "/" + cid,
                trackId = cid,
                index = idx + 1,
                durationMs = (p["duration"]?.optLong() ?: 0L) * 1000,
                coverUrl = book.coverUrl,
            )
        }
        return BookDetail(book, eps)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                val parts = url.substringAfterLast("play/", url).split("/")
                val aid = parts.getOrNull(0)?.toLongOrNull() ?: 0L
                val cid = parts.getOrNull(1)?.toLongOrNull()
                    ?: url.toLongOrNull()
                    ?: throw SourceErrors.ParseFailed("无法解析 aid/cid：" + url)
                val api = "https://api.bilibili.com/x/player/playurl" +
                    "?avid=" + aid + "&cid=" + cid + "&qn=64&fnval=16"
                val root = getJson(api)
                if (root.optInt("code") != 0) {
                    throw SourceErrors.Auth("B站播放接口失败：" + (root["message"]?.asStr() ?: ""))
                }
                val dash = root["data"]?.asObj()?.get("dash")?.asObj()
                val audios = dash?.get("audio")?.asArr() ?: JsonArray(emptyList())
                val best = audios.mapNotNull { it.asObj() }
                    .mapNotNull { it["baseUrl"]?.asStr() ?: it["base_url"]?.asStr() }
                    .firstOrNull()
                    ?: throw SourceErrors.ParseFailed("B站未返回音频轨")
                return ExtractedAudio(best, emptyMap(), 7_200L)
            }
        }

    private fun normalizeCover(raw: String): String = when {
        raw.isEmpty() -> ""
        raw.startsWith("//") -> "https:" + raw
        else -> raw
    }

    private suspend fun getJson(target: String): JsonObject {
        val headers = mapOf(
            "User-Agent" to UA,
            "Referer" to "https://www.bilibili.com/",
            "Cookie" to buvid3,
        )
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return runCatching { Json.parseToJsonElement(resp.text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON")
    }

    private fun JsonElement.asObj(): JsonObject? = runCatching { jsonObject }.getOrNull()
    private fun JsonElement.asArr(): JsonArray? = runCatching { jsonArray }.getOrNull()
    private fun JsonElement.asStr(): String? = (this as? JsonPrimitive)?.content
    private fun JsonObject.optInt(key: String): Int = (this[key] as? JsonPrimitive)?.content?.toIntOrNull() ?: -1
    private fun JsonElement.optInt(): Int? = (this as? JsonPrimitive)?.content?.toIntOrNull()
    private fun JsonElement.optLong(): Long? = (this as? JsonPrimitive)?.content?.toLongOrNull()

    companion object {
        const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"
    }
}
