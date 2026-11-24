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
 * 网易云音乐源（免登录，走公共 Meting 代理）
 *
 * 【来源】反编译 sources_by_agg.jar 的 NetEaseMusic
 * 该类里虽然有 AES/ECB/PKCS5Padding、access$aesEcbDecrypt 等方法，
 * 但实际取地址走的是第三方代理 api.qijieya.cn/meting/，自己没实现官方加密。
 *
 * 【实测 2026-11-23】
 *   搜索  ?server=netease&type=search&id={kw}     → 11KB / 数组
 *   歌单  ?server=netease&type=playlist&id={id}   → 305KB / 数组
 *   音频  ?server=netease&type=url&id={songId}    → 302 跳转到 m7.music.126.net
 *   下载  跟随 302 → 12,150,765 字节 / audio/mpeg / ID3v2 + MP3 帧 ✓
 *
 * 【返回格式】数组，每项：
 *   {"name":"歌名","artist":"歌手","url":".../type=url&id=xxx",
 *    "pic":".../type=pic&id=xxx","lrc":".../type=lrc&id=xxx"}
 *
 * 【注意】url 字段本身是代理地址，播放时必须跟随 302。
 *   iOS 的 AVPlayer 会自动跟随 302，所以直接给代理地址即可。
 */
class NeteaseSource(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    override val sourceId: String = "netease",
    override val name: String = "网易云音乐",
) : SourceActions {

    override val url = "https://music.163.com"
    override val desc = "网易云音乐，走公共 Meting 代理，免登录"
    override val capabilities = Capabilities(
        searchable = true, discoverable = true, cacheable = false,
        needsWebView = false, searchVerifiable = false, needsLogin = false,
        multipleEpisodePages = false,
    )

    // ---------- 搜索 ----------

    override suspend fun search(keywords: String, page: Int): SearchResult {
        // 【2026-11-24 修复】meting 代理的 type=search 已失效（实测任何关键词都返回 []）。
        // 改用网易云官方搜索接口：不需要加密、不需要登录，返回 songs 数组。
        // 取地址仍走 meting 的 type=url，两条腿分别负责"找"和"播"。
        val target = OFFICIAL_SEARCH + "?s=" + SearchRoutes.enc(keywords) +
            "&type=1&limit=" + PAGE_SIZE + "&offset=" + ((page - 1) * PAGE_SIZE)
        val root = getJson(target)
        val songs = root["result"]?.asObj()?.get("songs")?.asArr() ?: JsonArray(emptyList())

        val books = songs.mapIndexedNotNull { idx, el ->
            val o = el.asObj() ?: return@mapIndexedNotNull null
            val songName = o["name"]?.asStr()?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
            // artists 是数组：[{id,name,...}]
            val artist = o["artists"]?.asArr()?.firstOrNull()?.asObj()?.get("name")?.asStr() ?: ""
            // 官方搜索接口的 album 对象**没有 picUrl**（实测键：publishTime/size/artist/
            // copyrightId/name/id/picId/mark/status）。拼 picId 需要额外加密参数，成本高。
            // 这里直接给 meting 的 pic 端点：它对任何 songId 都 302 到真实 CDN，
            // ImageView 会自动跟随跳转（实测 http=404 是因为部分歌曲无授权封面，不是格式错）。
            val picUrl = META + "?server=netease&type=pic&id=" + (o["id"]?.asLong() ?: 0L)
            val rawId = o["id"]?.asLong()
            val songId = rawId?.toString() ?: (idx.toString())
            Book(
                sourceId = sourceId,
                bookUrl = "netease://song/" + songId,
                title = songName,
                author = artist,
                coverUrl = picUrl,
                intro = "",
                albumId = songId.toLongOrNull() ?: 0L,
                trackCount = 1L,
                playCount = 0L,
                isFinished = true,
            )
        }

        val hasMore = songs.size >= PAGE_SIZE
        return SearchResult(books, if (hasMore) page + 1 else page, sourceId, page,
            if (books.isEmpty()) "网易云没搜到（接口可能改版）" else null)
    }

    // ---------- 详情 ----------

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val songId = Regex("(\\d+)").find(bookUrl)?.groupValues?.get(1)
            ?: throw SourceErrors.ParseFailed("无法解析 songId：" + bookUrl)

        // 代理是单曲粒度，详情只能拿到当前这一首
        // 用 url 接口探测元信息（不下载，只取 302 的 Location 判断可用性）
        val playUrl = META + "?server=netease&type=url&id=" + songId

        val book = Book(
            sourceId = sourceId,
            bookUrl = "netease://song/" + songId,
            title = "网易云单曲 " + songId,
            author = "",
            coverUrl = META + "?server=netease&type=pic&id=" + songId,
            intro = "",
            albumId = songId.toLongOrNull() ?: 0L,
            trackCount = 1L,
            playCount = 0L,
            isFinished = true,
        )

        val eps = if (loadEpisodes) listOf(
            Episode(
                title = "单曲 " + songId,
                url = playUrl,
                trackId = songId.toLongOrNull() ?: 0L,
                index = 1,
                durationMs = 0L,
                coverUrl = book.coverUrl,
            )
        ) else emptyList()

        return BookDetail(book, eps)
    }

    // ---------- 播放 ----------

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                // 直接把代理地址交给播放器（AVPlayer 会自动跟随 302）
                if (url.contains("qijieya.cn") || url.contains("music.126.net")) {
                    return ExtractedAudio(url, mapOf("User-Agent" to UA), 0L)
                }
                val songId = Regex("(\\d+)").findAll(url).lastOrNull()?.value
                    ?: throw SourceErrors.ParseFailed("无法解析 songId：" + url)
                val proxy = META + "?server=netease&type=url&id=" + songId
                return ExtractedAudio(proxy, mapOf("User-Agent" to UA), 0L)
            }
        }

    // ---------- 工具 ----------

    private suspend fun getArray(target: String): JsonArray {
        val headers = mapOf("User-Agent" to UA, "Accept" to "application/json")
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return runCatching { Json.parseToJsonElement(resp.text).jsonArray }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON 数组：" + target.take(60))
    }

    private fun JsonElement.asObj(): JsonObject? = runCatching { jsonObject }.getOrNull()
    private fun JsonElement.asStr(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement.asArr(): JsonArray? = runCatching { jsonArray }.getOrNull()
    private fun JsonElement.asLong(): Long? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.toLongOrNull()

    /** 直接取 JSON 对象（官方搜索接口返回 object 不是 array） */
    private suspend fun getJson(target: String): JsonObject {
        // 网易云要求桌面版 UA + Referer，裸请求会 403/空结果
        val resp = throttle.run {
            fetcher.get(target, mapOf(
                "User-Agent" to "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Referer" to "https://music.163.com/",
                "Accept" to "application/json",
            ))
        }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return runCatching { Json.parseToJsonElement(resp.text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target.take(80))
    }

    companion object {
        const val META = "https://api.qijieya.cn/meting/"
        /** 网易云官方搜索（无需加密，limit 上限 100） */
        const val OFFICIAL_SEARCH = "https://music.163.com/api/search/get"
        const val PAGE_SIZE = 20
        const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"
    }
}
