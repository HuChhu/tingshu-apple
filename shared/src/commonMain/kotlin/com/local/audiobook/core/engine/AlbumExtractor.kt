package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

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
