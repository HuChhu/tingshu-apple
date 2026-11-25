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
import com.local.audiobook.data.ximalaya.engine.Crypto
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
 * 蜻蜓 FM 源（免登录 + HMAC 签名）
 *
 * 【来源】反编译 sources_by_agg.jar 的 QingTingFM + QingTingFM$getAudioUrlExtractor$1
 *
 * 【完全解开的签名机制】
 *   密钥   HMAC_KEY = "7l8CZ)SgZgM_bkrw"
 *   算法   HMAC-MD5，输出 hex
 *   被签串 "/audiostream/redirect/{channelId}/{programId}" +
 *          "?access_token=&device_id=MOBILESITE&qingting_id=&t={毫秒时间戳}"
 *   （注意：签的是路径+参数，**不含域名**）
 *
 * 【端点】
 *   搜索  https://search.qtfm.cn/v3/search?categoryid=0&k={kw}&page={p}
 *         → 27KB / 30 条 / program_ondemand
 *   频道  https://i.qtfm.cn/capi/channel/{channelId}
 *         → 2.5KB / title / cover / description / program_count
 *   音频  https://audio.qtfm.cn{被签串}&sign={hmacMd5}
 *         → 597,179 字节 / ftypM4A ✓
 *
 * 【实测 2026-11-23】搜索和频道不需要签名，只有音频需要
 */
class QingtingSource(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    private val nowMs: () -> Long,
    override val sourceId: String = "qingting",
    override val name: String = "蜻蜓FM",
) : SourceActions {

    override val url = "https://m.qtfm.cn"
    override val desc = "蜻蜓FM，免登录，音频地址用 HMAC-MD5 签名"
    override val capabilities = Capabilities(
        searchable = true, discoverable = false, cacheable = false,
        needsWebView = false, searchVerifiable = false, needsLogin = false,
        multipleEpisodePages = false,
    )

    // ---------- 搜索 ----------

    override suspend fun search(keywords: String, page: Int): SearchResult {
        val target = "https://search.qtfm.cn/v3/search?categoryid=0&k=" +
            SearchRoutes.enc(keywords) + "&page=" + page
        val root = getJson(target)

        // 结构：data.data.docs[]
        val docs = root["data"]?.asObj()?.get("data")?.asObj()?.get("docs")?.asArr()
            ?: JsonArray(emptyList())

        val books = docs.mapNotNull { el ->
            val o = el.asObj() ?: return@mapNotNull null
            val channelId = o["parent_id"]?.optLong() ?: return@mapNotNull null
            val title = o["title"]?.asStr()?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            Book(
                sourceId = sourceId,
                bookUrl = "https://m.qtfm.cn/channels/" + channelId,
                title = title,
                author = "",
                coverUrl = o["cover"]?.asStr() ?: "",
                intro = o["description"]?.asStr()?.take(300) ?: "",
                albumId = channelId,
                trackCount = 0L,
                playCount = o["playcount"]?.optLong() ?: 0L,
                isFinished = false,
            )
        }

        return SearchResult(books, if (books.isNotEmpty()) page + 1 else page, sourceId, page,
            if (books.isEmpty()) "蜻蜓没搜到" else null)
    }

    // ---------- 频道详情 ----------

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean,
                                cancel: com.local.audiobook.core.CancelToken): BookDetail {
        val channelId = Regex("channels/(\\d+)").find(bookUrl)?.groupValues?.get(1)
            ?: bookUrl.filter { it.isDigit() }.takeIf { it.isNotEmpty() }
            ?: throw SourceErrors.ParseFailed("无法解析 channelId：" + bookUrl)

        val root = getJson("https://i.qtfm.cn/capi/channel/" + channelId)
        val d = root["data"]?.asObj() ?: throw SourceErrors.NotFound(bookUrl)

        val book = Book(
            sourceId = sourceId,
            bookUrl = "https://m.qtfm.cn/channels/" + channelId,
            title = d["title"]?.asStr() ?: ("蜻蜓频道 " + channelId),
            author = d["podcasters"]?.asArr()?.joinToString(" ") {
                it.asObj()?.get("nick_name")?.asStr() ?: ""
            }?.trim() ?: "",
            coverUrl = d["cover"]?.asStr() ?: "",
            intro = d["description"]?.asStr()?.take(500) ?: "",
            albumId = channelId.toLongOrNull() ?: 0L,
            trackCount = d["program_count"]?.optLong() ?: 0L,
            playCount = d["playcount"]?.optLong() ?: 0L,
            isFinished = d["finished"]?.asStr() == "1",
        )

        // P0-1：latest_program 可能是字符串（标题）也可能是对象（含 id）。
        // 实测 i.qtfm.cn/capi/channel/403408 返回的是字符串，asObj() 得 null → 永远 0 章。
        val eps = mutableListOf<Episode>()
        when (val lp = d["latest_program"]) {
            is JsonObject -> {
                val pid = lp["id"]?.optLong()
                if (pid != null) {
                    eps.add(Episode(
                        title = lp["title"]?.asStr() ?: "最新一期",
                        url = "qtfm://play/" + channelId + "/" + pid,
                        trackId = pid,
                        index = 1,
                        durationMs = (lp["duration"]?.optLong() ?: 0L) * 1000,
                        coverUrl = book.coverUrl,
                    ))
                }
            }
            is JsonPrimitive -> {
                // 字符串形态：只有标题，没有 id。尝试用搜索结果的 program id 兜底。
                // 搜索时 parent_id 就是 channelId，id 是 program id。
                // 这里如果没有 id，只能提示「需通过搜索进入该集」。
                val title = lp.content
                if (title.isNotBlank()) {
                    eps.add(Episode(
                        title = title,
                        url = "qtfm://channel/" + channelId + "/latest",
                        trackId = 0L,
                        index = 1,
                        durationMs = 0L,
                        coverUrl = book.coverUrl,
                    ))
                }
            }
            else -> {}
        }

        return BookDetail(book, if (loadEpisodes) eps else emptyList())
    }

    // ---------- 音频（HMAC 签名） ----------

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                // 两种 URL 形态：
                //   qtfm://play/{channelId}/{programId}   正常单集
                //   qtfm://channel/{channelId}/latest    字符串型 latest_program 的兜底
                var channelId: String
                var programId: Long
                if (url.contains("/channel/")) {
                    channelId = url.substringAfterLast("channel/", "").substringBefore("/")
                    // 再取一次频道详情，拿最新一集的 id（这次可能是对象形态）
                    val detail = getJson("https://i.qtfm.cn/capi/channel/" + channelId)
                    val lp = detail["data"]?.asObj()?.get("latest_program")
                    programId = when (lp) {
                        is JsonObject -> lp["id"]?.optLong() ?: 0L
                        else -> 0L
                    }
                    if (programId == 0L) throw SourceErrors.ParseFailed("该频道没有可播放的节目")
                } else {
                    val parts = url.substringAfterLast("play/", url).split("/")
                    channelId = parts.getOrNull(0) ?: throw SourceErrors.ParseFailed("缺 channelId")
                    programId = parts.getOrNull(1)?.toLongOrNull()
                        ?: throw SourceErrors.ParseFailed("缺 programId")
                }

                val ts = nowMs().toString()
                // 被签名的串：路径 + 参数（不含域名）
                val signedPath = "/audiostream/redirect/" + channelId + "/" + programId +
                    "?access_token=&device_id=MOBILESITE&qingting_id=&t=" + ts
                val sign = Crypto.hmacMd5Hex(signedPath, HMAC_KEY)

                val full = "https://audio.qtfm.cn" + signedPath + "&sign=" + sign
                return ExtractedAudio(full, mapOf("User-Agent" to UA), 0L)
            }
        }

    // ---------- 工具 ----------

    private suspend fun getJson(target: String): JsonObject {
        val headers = mapOf(
            "User-Agent" to UA,
            "Referer" to "https://m.qtfm.cn/",
            "Accept" to "application/json",
        )
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        return runCatching { Json.parseToJsonElement(resp.text).jsonObject }.getOrNull()
            ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target.take(60))
    }

    private fun JsonElement.asObj(): JsonObject? = runCatching { jsonObject }.getOrNull()
    private fun JsonElement.asArr(): JsonArray? = runCatching { jsonArray }.getOrNull()
    private fun JsonElement.asStr(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement.optLong(): Long? = (this as? JsonPrimitive)?.content?.toLongOrNull()

    companion object {
        /** 从 jar 里逆出的 HMAC 密钥 */
        const val HMAC_KEY = "7l8CZ)SgZgM_bkrw"
        const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"
    }
}
