package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// 对拍基准：bridge api.py _extract_albums_mobile/_extract_albums_web + 类目抽取（§18.2）
object AlbumExtractor {
    private fun collect(arr: JsonArray, sourceId: String): List<Book> = arr.mapNotNull { el ->
        val o = el as? JsonObject ?: return@mapNotNull null
        val album = o["album"] as? JsonObject ?: o
        val b = AlbumNormalizer.normalizeAlbum(album, sourceId)
        if (b.albumId > 0) b else null
    }

    fun fromMobile(data: JsonObject, sourceId: String): List<Book> {
        val body = data["data"] as? JsonObject ?: data
        for (key in listOf("albums", "albumList", "docs", "list")) {
            val arr = body[key] as? JsonArray ?: continue
            val out = collect(arr, sourceId)
            if (out.isNotEmpty()) return out
        }
        return emptyList()
    }

    /**
     * search.ximalaya.com/front/v1 的响应（实测字段，与 revision 接口不同名）：
     *   id / title / nickname / cover_path / intro / play / tracks / is_finished(2=完结)
     * 没有 albumId、没有 anchorName、没有 trackCount —— 全部在这里映射一次，
     * 不让调用方各自猜字段名（之前就是这么错的）。
     */
    fun fromSearchFront(data: JsonObject?, sourceId: String): List<Book> {
        val docs = data?.get("response")
            ?.let { runCatching { it.jsonObject["docs"] }.getOrNull() }
            ?.let { runCatching { it.jsonArray }.getOrNull() } ?: return emptyList()
        return docs.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val albumId = (o["id"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return@mapNotNull null
            val title = (o["title"] as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() }
                ?: (o["custom_title"] as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            val coverRaw = (o["cover_path"] as? JsonPrimitive)?.content ?: ""
            val cover = when {
                coverRaw.startsWith("//") -> "https:" + coverRaw
                coverRaw.startsWith("http") -> coverRaw
                coverRaw.isEmpty() -> ""
                else -> "https://imagev2.xmcdn.com/" + coverRaw.trimStart('/')
            }
            Book(
                sourceId = sourceId,
                bookUrl = "https://www.ximalaya.com/album/" + albumId,
                title = title,
                author = (o["nickname"] as? JsonPrimitive)?.content ?: "",
                coverUrl = cover,
                intro = (o["intro"] as? JsonPrimitive)?.content?.replace(Regex("<[^>]+>"), "")?.take(500) ?: "",
                albumId = albumId,
                trackCount = (o["tracks"] as? JsonPrimitive)?.content?.toLongOrNull()
                    ?: (o["trackCount"] as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L,
                playCount = (o["play"] as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L,
                isFinished = when ((o["is_finished"] as? JsonPrimitive)?.content) {
                    "true", "1", "2" -> true
                    "false", "0", "3" -> false
                    else -> null
                },
            )
        }
    }

    fun fromWeb(data: JsonObject, sourceId: String): List<Book> {
        val docs = (((data["data"] as? JsonObject)?.get("album") as? JsonObject)?.get("docs")) as? JsonArray
            ?: return emptyList()
        return collect(docs, sourceId)
    }

    fun fromCategory(data: JsonObject, sourceId: String): List<Book> {
        val arr = (data["data"] as? JsonObject)?.get("albums") as? JsonArray ?: return emptyList()
        return collect(arr, sourceId)
    }
}
