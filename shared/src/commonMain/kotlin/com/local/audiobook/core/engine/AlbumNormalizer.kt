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
    /**
     * 取第一个**非空**的字符串字段。
     *
     * 2026-11-25：以前是 pick(...)?.content ?: ""，而 pick 只要拿到 JsonPrimitive 就返回 ——
     * 空串也是 JsonPrimitive。于是 str(t,"playUrl64","playUrl32") 在 playUrl64="" 时
     * 永远读不到 playUrl32，把「有 32 直链」的轨道判成不可播。
     * 这里改成逐个 key 找第一个非空值；pick 本身不动（其它字段依赖它的 null 语义）。
     */
    fun str(o: JsonObject?, vararg keys: String): String {
        for (k in keys) {
            val v = o?.get(k)
            if (v == null || v is kotlinx.serialization.json.JsonNull) continue
            val c = (v as? kotlinx.serialization.json.JsonPrimitive)?.content ?: continue
            // isNotBlank 而不是 isNotEmpty：上游偶发给纯空格（"   "），
            // isNotEmpty 会把它当有效值返回，书名显示成空白、playUrl 变成一串空格。
            if (c.isNotBlank()) return c
        }
        return ""
    }
    fun lng(o: JsonObject?, vararg keys: String) = pick(o, *keys)?.content?.trim()?.toLongOrNull() ?: 0L

    /** 布尔字段。上游有 true / "true" / 1 / "1" 四种写法，全认。 */
    fun bool(o: JsonObject?, vararg keys: String): Boolean {
        val raw = pick(o, *keys)?.content?.trim()?.lowercase() ?: return false
        return raw == "true" || raw == "1"
    }
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
        playCount = lng(a, "playCount", "albumPlayCount", "playTimes", "play_cnt"),
        isFinished = finishedFlag(a),
    )

    /**
     * 喜马拉雅的 isFinished 是数字：1=连载中，2=已完结（实测 76301417 返回 2）。
     * 其它源可能给 bool 或 "true"/"1"。统一转成 Boolean?
     */
    private fun finishedFlag(a: JsonObject): Boolean? {
        val e = a["isFinished"] ?: return null
        val s = (e as? JsonPrimitive)?.content ?: return null
        return when (s.lowercase()) {
            "true", "1", "2", "finished", "complete" -> true
            "false", "0", "3", "ongoing" -> false
            else -> null
        }
    }
}
