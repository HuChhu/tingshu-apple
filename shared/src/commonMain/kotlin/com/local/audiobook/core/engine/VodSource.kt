package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import com.local.audiobook.core.BookDetail
import com.local.audiobook.core.Episode
import com.local.audiobook.core.SearchResult
import com.local.audiobook.core.SourceErrors
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * ============================================================
 *  通用影视/音频采集源（provide/vod 协议）
 * ============================================================
 *
 * 【协议来源】逆向「我的听书」的外置 jar 时发现：它有 29 个影视资源站
 * 全部使用同一套国内 CMS 采集协议。这是行业通用标准，不是某个 App 私有。
 *
 * 【协议规范】
 *   列表  GET {base}/api.php/provide/vod/?ac=list&pg=N
 *   详情  GET {base}/api.php/provide/vod/?ac=detail&ids={id}
 *   搜索  GET {base}/api.php/provide/vod/?wd={keyword}&pg=N
 *
 *   返回 JSON：
 *   {
 *     "code":1, "msg":"数据列表", "page":1, "pagecount":100, "total":2000,
 *     "list":[{
 *       "vod_id":1, "vod_name":"片名", "vod_pic":"封面",
 *       "type_name":"剧情片", "vod_year":"2021", "vod_remarks":"HD",
 *       "vod_play_url":"第1集$https://x/1.m3u8#第2集$https://x/2.m3u8"
 *     }]
 *   }
 *
 *   vod_play_url 编码规则：
 *     # 分隔集    $ 分隔集名与地址    $$$ 分隔多线路
 *
 * 【为什么值得接入】
 *   ① 不需要登录、不需要签名、不需要反爬
 *   ② 返回标准 JSON，字段稳定
 *   ③ 直接给 .m3u8 直链
 *   ④ **一改多** —— 29 个站同一协议，一个解析器通吃
 *
 * 这比啃喜马拉雅的极验滑块现实得多，作为「第二条腿」接入。
 */
class VodSource(
    private val baseUrl: String,
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    override val sourceId: String,
    override val name: String,
) : com.local.audiobook.core.SourceActions {

    override val url = baseUrl
    override val desc = "通用采集协议源（provide/vod），免登录"
    override val capabilities = com.local.audiobook.core.Capabilities(
        searchable = true, discoverable = true, cacheable = true, needsWebView = false,
    )

    private val api = baseUrl.trimEnd('/') + "/api.php/provide/vod/"

    // ---------- 搜索 ----------

    override suspend fun search(keywords: String, page: Int): SearchResult {
        val target = api + "?wd=" + enc(keywords) + "&pg=" + page
        val obj = getJson(target)
        val list = obj["list"]?.jsonArray ?: JsonArray(emptyList())
        val books = list.mapNotNull { it.asObj()?.toBook() }
        val pageCount = obj["pagecount"]?.asInt() ?: 1
        return SearchResult(
            books = books,
            maxPage = pageCount,
            source = sourceId,
            page = page,
            hint = if (books.isEmpty()) "该源没有这本书" else null,
        )
    }

    // ---------- 详情 ----------

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val id = bookUrl.substringAfterLast('/').substringBefore('?')
        if (id.isEmpty()) throw SourceErrors.ParseFailed("bookUrl 里没有 id：" + bookUrl)

        val target = api + "?ac=detail&ids=" + id
        val obj = getJson(target)
        val list = obj["list"]?.jsonArray ?: JsonArray(emptyList())
        val item = list.firstOrNull()?.asObj() ?: throw SourceErrors.NotFound(bookUrl)

        val book = item.toBook() ?: throw SourceErrors.NotFound(bookUrl)
        val episodes = if (loadEpisodes) parsePlayUrl(item["vod_play_url"]?.asStr() ?: "", id) else emptyList()
        return BookDetail(book, episodes)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): com.local.audiobook.core.ExtractedAudio {
                // 这个协议直接给 .m3u8 / .mp4 直链，不需要二次提取
                if (!AudioUrlHeaders.isDirectAudio(url) && !url.contains(".m3u8")) {
                    throw SourceErrors.ParseFailed("不是可播放直链：" + url)
                }
                return com.local.audiobook.core.ExtractedAudio(
                    url = url,
                    headers = AudioUrlHeaders.headersFor(url),
                    expiresInSeconds = 0L,
                )
            }
        }

    // ---------- 解析 ----------

    private fun JsonObject.toBook(): Book? {
        val id = this["vod_id"]?.asStr()?.takeIf { it.isNotEmpty() } ?: return null
        val title = this["vod_name"]?.asStr()?.takeIf { it.isNotBlank() } ?: return null
        val playUrlStr = this["vod_play_url"]?.asStr() ?: ""
        val epCount = if (playUrlStr.isBlank()) 0L else playUrlStr.split('#').size.toLong()
        return Book(
            sourceId = sourceId,
            bookUrl = baseUrl.trimEnd('/') + "/vod/" + id,
            title = title,
            author = this["vod_director"]?.asStr() ?: this["type_name"]?.asStr() ?: "",
            coverUrl = this["vod_pic"]?.asStr() ?: "",
            intro = this["vod_content"]?.asStr()?.replace(Regex("<[^>]+>"), "")?.take(300) ?: "",
            albumId = id.toLongOrNull() ?: 0L,
            trackCount = epCount,
            playCount = 0L,
            isFinished = (this["vod_remarks"]?.asStr() ?: "").contains("全") ||
                         (this["vod_remarks"]?.asStr() ?: "").contains("完"),
        )
    }

    /**
     * 解析 vod_play_url。
     * 格式：第1集$https://x/1.m3u8#第2集$https://x/2.m3u8
     * 多线路用 $$$ 分隔，只取第一条线路。
     */
    internal fun parsePlayUrl(raw: String, vodId: String): List<Episode> {
        if (raw.isBlank()) return emptyList()
        // 取第一条线路（$$$ 之前）
        val firstLine = raw.substringBefore("$$$")
        return firstLine.split('#').mapIndexedNotNull { idx, seg ->
            if (seg.isBlank()) return@mapIndexedNotNull null
            val name = seg.substringBefore('$').trim()
            val addr = seg.substringAfter('$', "").trim()
            if (addr.isEmpty()) return@mapIndexedNotNull null
            Episode(
                title = name.ifEmpty { "第" + (idx + 1) + "集" },
                url = addr,
                trackId = (vodId.toLongOrNull() ?: 0L) * 100000 + idx,
                index = idx + 1,
                durationMs = 0L,
                coverUrl = "",
            )
        }
    }

    // ---------- HTTP ----------

    private suspend fun getJson(target: String): JsonObject {
        val headers = mapOf(
            "User-Agent" to SearchRoutes.MOBILE_UA,
            "Accept" to "application/json",
        )
        val resp = throttle.run { fetcher.get(target, headers) }
        if (resp !is FetchOutcome.Ok) {
            throw SourceErrors.Network((resp as FetchOutcome.Failed).kind)
        }
        return runCatching {
            Json.parseToJsonElement(resp.text).jsonObject
        }.getOrNull() ?: throw SourceErrors.ParseFailed("响应非 JSON：" + target)
    }

    private fun enc(s: String): String = SearchRoutes.enc(s)

    // JsonElement 小工具（避免依赖内部实现）
    private fun kotlinx.serialization.json.JsonElement.asObj(): JsonObject? =
        runCatching { this.jsonObject }.getOrNull()

    private fun kotlinx.serialization.json.JsonElement.asStr(): String? =
        (this as? JsonPrimitive)?.contentOrNullSafe()

    private fun kotlinx.serialization.json.JsonElement.asInt(): Int? =
        (this as? JsonPrimitive)?.contentOrNullSafe()?.toIntOrNull()

    private fun JsonPrimitive.contentOrNullSafe(): String? =
        if (this.isString) this.content else this.content
}
