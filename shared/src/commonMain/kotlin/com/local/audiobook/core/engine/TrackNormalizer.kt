package com.local.audiobook.core.engine

import com.local.audiobook.core.Episode
import kotlinx.serialization.json.JsonObject

// 对拍基准：bridge api.py normalize_track 回退链 + 曲目索引数学（baseIndex=(page-1)*pageSize）
// bridge 缺陷修正③（M2 实录发现，待回写 bridge）：上游 duration 是「秒」，bridge 直接存进
// durationMs 字段名下（单位误导）。本引擎统一换算 ×1000，对拍差异按单位修正解释。
object TrackNormalizer {

    fun indexAt(page: Int, pageSize: Int, i: Int): Int = (page - 1) * pageSize + i + 1

    fun maxPage(trackCount: Long, pageSize: Int): Long =
        if (pageSize <= 0 || trackCount <= 0) 0 else (trackCount + pageSize - 1) / pageSize

    fun normalizeTrack(t: JsonObject, index: Int, sourceId: String): Episode {
        val trackId = AlbumNormalizer.lng(t, "trackId", "id")
        return Episode(
            title = AlbumNormalizer.str(t, "title", "trackTitle"),
            url = DetailRoutes.soundUrl(trackId),
            trackId = trackId,
            index = index,
            durationMs = AlbumNormalizer.lng(t, "duration", "length") * 1000L,   // 秒→毫秒（③）
            coverUrl = SearchRoutes.coverUrl(AlbumNormalizer.str(t, "cover", "coverLarge", "coverMiddle")),
        )
    }
}
