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
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * 酷我听书源（免登录）
 *
 * 【来源】反编译 sources_by_agg.jar 的 KuWoTing
 * 【实测 2026-11-23】
 *   搜索  tingshu.kuwo.cn/tingshu/api/search/Search 200 / 133 条
 *   详情  search.kuwo.cn/r.s?stype=albuminfo      200 / 305KB / 97 集
 *   播放  antiserver.kuwo.cn/anti.s               200 / 直链 / 181KB 实测可下载
 *
 * 注意：酷我返回 Python dict 格式（单引号 + &nbsp;），需要预处理
 */
class KuwoSource(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    override val sourceId: String = "kuwo",
    override val name: String = "酷我听书",
) : SourceActions {

    override val url = "http://tingshu.kuwo.cn"
    override val desc = "酷我音乐有声书，免登录"
    override val capabilities = Capabilities(
        searchable = true, discoverable = true, cacheable = true,
        needsWebView = false, searchVerifiable = false, needsLogin = false,
        multipleEpisodePages = false,
    )

    override suspend fun search(keywords: String, page: Int): SearchResult {
        val target = MOBILE_BASE + "/tingshu/api/search/Search?rn=10&type=album&version=8.5.6.1&wd=" +
            SearchRoutes.enc(keywords)
        val root = getJson(target)
        val arr = root["data"]?.asObj()?.get("data")?.asArr() ?: JsonArray(emptyList())
        val books = arr.mapNotNull { el ->
            val o = el.asObj() ?: return@mapNotNull null
            val id = o["albumId"]?.asStr()?.toLongOrNull() ?: return@mapNotNull null
            val title = o["albumName"]?.asStr() ?: o["name"]?.asStr() ?: return@mapNotNull null
            Book(
                sourceId = sourceId, bookUrl = "kuwo://album/" + id, title = title,
                author = o["artist"]?.asStr() ?: "", coverUrl = o["coverImg"]?.asStr() ?: "",
                intro = "", albumId = id,
                trackCount = o["songTotal"]?.asStr()?.toLongOrNull() ?: 0L,
                playCount = o["playCnt"]?.asStr()?.toLongOrNull() ?: 0L,
                isFinished = o["finished"]?.asStr() == "1",
            )
        }
        return SearchResult(books, if (books.size >= 10) page + 1 else page, sourceId, page,
            if (books.isEmpty()) "酷我没搜到这本书" else null)
    }

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val albumId = Regex("(\\d+)").findAll(bookUrl).lastOrNull()?.value?.toLongOrNull()
            ?: throw SourceErrors.ParseFailed("无法解析 albumId：" + bookUrl)
        val target = SEARCH_BASE + "/r.s?stype=albuminfo&albumid=" + albumId +
            "&loginUid=0&loginSid=null&prod=kwplayer_ar_9.1.7.0&bkprod=kwbook.9.1.7.0&pn=0&rn=200"
        val text = getText(target)
        val cleaned = text.replace("'", "\"").replace("&nbsp;", " ")
        val root = runCatching { Json.parseToJsonElement(cleaned).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("酷我响应无法解析")

        val book = Book(
            sourceId = sourceId, bookUrl = "kuwo://album/" + albumId,
            title = root["album"]?.asStr() ?: root["name"]?.asStr() ?: ("酷我专辑 " + albumId),
            author = root["artist"]?.asStr() ?: "",
            coverUrl = root["img"]?.asStr() ?: root["hts_img"]?.asStr() ?: "",
            intro = root["info"]?.asStr()?.take(300) ?: "",
            albumId = albumId,
            trackCount = root["songnum"]?.asStr()?.toLongOrNull() ?: 0L,
            playCount = 0L, isFinished = root["finished"]?.asStr() == "1",
        )

        if (!loadEpisodes) return BookDetail(book, emptyList())

        val list = root["musiclist"]?.asArr() ?: JsonArray(emptyList())
        val eps = list.mapIndexedNotNull { idx, el ->
            val o = el.asObj() ?: return@mapIndexedNotNull null
            val rid = o["rid"]?.asStr()?.toLongOrNull()
                ?: o["musicrid"]?.asStr()?.toLongOrNull()
                ?: o["id"]?.asStr()?.toLongOrNull() ?: return@mapIndexedNotNull null
            val dur = o["duration"]?.asStr()?.toLongOrNull() ?: 0L
            Episode(
                title = o["name"]?.asStr() ?: o["songname"]?.asStr() ?: ("第" + (idx + 1) + "集"),
                url = "https://www.kuwo.cn/play_detail/" + rid,
                trackId = rid, index = idx + 1, durationMs = dur * 1000,
                coverUrl = o["pic120"]?.asStr() ?: "",
            )
        }
        return BookDetail(book, eps)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                val rid = Regex("(\\d+)").findAll(url).lastOrNull()?.value
                    ?: throw SourceErrors.ParseFailed("无法解析 rid：" + url)
                val api = "http://antiserver.kuwo.cn/anti.s" +
                    "?type=convert_url&format=mp3&response=url&rid=MUSIC_" + rid
                val body = getText(api).trim()
                if (!body.startsWith("http")) {
                    throw SourceErrors.ParseFailed("酷我未返回直链：" + body.take(60))
                }
                return ExtractedAudio(body, emptyMap(), 0L)
            }
        }

    private suspend fun getText(target: String): String {
        val headers = mapOf("User-Agent" to MOBILE_UA, "Accept" to "application/json")
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return resp.text
    }

    private suspend fun getJson(target: String): JsonObject {
        val text = getText(target)
        return runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target.take(60))
    }

    private fun JsonElement.asObj(): JsonObject? = runCatching { jsonObject }.getOrNull()
    private fun JsonElement.asArr(): JsonArray? = runCatching { jsonArray }.getOrNull()
    private fun JsonElement.asStr(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    companion object {
        const val MOBILE_BASE = "http://tingshu.kuwo.cn"
        const val SEARCH_BASE = "https://search.kuwo.cn"
        const val MOBILE_UA = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36"
    }
}
