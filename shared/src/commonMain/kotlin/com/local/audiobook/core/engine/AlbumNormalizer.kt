package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// 对拍基准：bridge api.py normalize_album 字段回退链（_pick 语义）
// 类目端点扩展键（albumUserNickName/albumCoverPath/albumTrackCount/albumPlayCount）按同语义补齐，
// 既有键优先级不变——差异已记录，待 lead 确认后回写 bridge。
object AlbumNormalizer {
    fun pick(o: JsonObject?, vararg keys: String): JsonPrimitive? {
        if (o == null) return null
        for (k in keys) {
            val v = o[k]
            if (v != null && v !is JsonNull && v is JsonPrimitive) return v
        }
        return null
    }
    fun str(o: JsonObject?, vararg keys: String) = pick(o, *keys)?.content ?: ""
    fun lng(o: JsonObject?, vararg keys: String) = pick(o, *keys)?.content?.trim()?.toLongOrNull() ?: 0L
    fun boo(o: JsonObject?, vararg keys: String) = pick(o, *keys)?.content?.let { it == "true" }

    fun normalizeAlbum(a: JsonObject, sourceId: String) = Book(
        sourceId = sourceId,
        bookUrl = SearchRoutes.albumUrl(lng(a, "albumId", "id")),
        title = str(a, "title", "albumTitle"),
        author = str(a, "author", "nickname", "anchorName", "albumUserNickName"),
        coverUrl = SearchRoutes.coverUrl(str(a, "cover", "coverLarge", "coverMiddle", "albumCover", "albumCoverPath")),
        intro = str(a, "intro", "description", "shortIntro"),
        albumId = lng(a, "albumId", "id"),
        trackCount = lng(a, "tracks", "trackCount", "totalCount", "albumTrackCount"),
        playCount = lng(a, "playCount", "albumPlayCount"),
        isFinished = boo(a, "isFinished"),
    )
}
