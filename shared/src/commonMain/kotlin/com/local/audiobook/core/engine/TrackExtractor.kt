package com.local.audiobook.core.engine

import com.local.audiobook.core.Episode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

// 曲目抽取（bridge 缺陷修正②，M2 live 实锤）：
// 真实响应 data.tracks 是分页信封 dict（list/maxPageId/pageId/pageSize/totalCount），
// 曲目列表在 data.tracks.list；bridge api.py 直接把 data.tracks 当列表读——该路径从未实跑（§17.7）。
// 本抽取器以信封为主形态，同时兼容裸列表（防御上游变体），并暴露 totalCount/maxPageId 给翻页循环。
object TrackExtractor {

    data class TrackPage(val episodes: List<Episode>, val totalCount: Long, val maxPageId: Long)

    /**
     * 免登录移动端响应（mobwsa / mobile /v1/album/track）：
     *   {"list":[{trackId,title,playUrl64,playUrl32,...}], "totalCount":N, "maxPageId":M}
     * 它和登录版的区别是：**直接带音频直链**，而登录版只给 trackId。
     */
    fun fromOpenList(root: JsonObject, page: Int, pageSize: Int, sourceId: String): TrackPage {
        val list = (root["list"] as? JsonArray)
            ?: ((root["data"] as? JsonObject)?.get("list") as? JsonArray)
            ?: JsonArray(emptyList())
        val episodes = list.mapIndexedNotNull { i, el ->
            val o = el as? JsonObject ?: return@mapIndexedNotNull null
            TrackNormalizer.normalizeTrack(o, TrackNormalizer.indexAt(page, pageSize, i), sourceId)
        }
        val totalCount = AlbumNormalizer.lng(root, "totalCount")
        val maxPageId = AlbumNormalizer.lng(root, "maxPageId")
        return TrackPage(episodes, totalCount, maxPageId)
    }

    fun fromDetail(data: JsonObject, page: Int, pageSize: Int, sourceId: String): TrackPage {
        val node = data["tracks"]
        val list: JsonArray?
        var totalCount = 0L
        var maxPageId = 0L
        when (val t = node) {
            is JsonObject -> {                       // 信封（实录主形态）
                list = t["list"] as? JsonArray
                totalCount = AlbumNormalizer.lng(t, "totalCount")
                maxPageId = AlbumNormalizer.lng(t, "maxPageId")
            }
            is JsonArray -> list = t                 // 裸列表（防御形态）
            else -> list = null
        }
        val episodes = (list ?: JsonArray(emptyList())).mapIndexedNotNull { i, el ->
            val o = el as? JsonObject ?: return@mapIndexedNotNull null
            TrackNormalizer.normalizeTrack(o, TrackNormalizer.indexAt(page, pageSize, i), sourceId)
        }
        return TrackPage(episodes, totalCount, maxPageId)
    }
}
