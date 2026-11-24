package com.local.audiobook.core.engine

import com.local.audiobook.core.Episode
import kotlinx.serialization.json.JsonObject

// 对拍基准：bridge api.py normalize_track 回退链 + 曲目索引数学（baseIndex=(page-1)*pageSize）
// bridge 缺陷修正③（M2 实录发现，待回写 bridge）：上游 duration 是「秒」，bridge 直接存进
// durationMs 字段名下（单位误导）。本引擎统一换算 ×1000，对拍差异按单位修正解释。
object TrackNormalizer {

    /** 只接受真正能播的直链（网页地址不算） */
    private fun firstPlayableUrl(vararg candidates: String): String? =
        candidates.firstOrNull { it.isNotEmpty() && AudioUrlHeaders.isPlayableAudio(it) }

    /** 供调用方判断：这个 track 是否已经带直链（免登录源不用再去换） */
    fun directAudio(t: JsonObject): String? = firstPlayableUrl(
        AlbumNormalizer.str(t, "playUrl64", "playUrl32", "playUrl", "src", "url", "downloadUrl")
    )

    fun indexAt(page: Int, pageSize: Int, i: Int): Int = (page - 1) * pageSize + i + 1

    fun maxPage(trackCount: Long, pageSize: Int): Long =
        if (pageSize <= 0 || trackCount <= 0) 0 else (trackCount + pageSize - 1) / pageSize

    /**
     * Episode.url 的语义：**播放时要交给 audio() 的入参**，不是音频地址。
     *
     * 旧实现固定给 DetailRoutes.soundUrl(trackId)，就是 https://www.ximalaya.com/sound/{id} ——
     * 这是**网页**。真机上它被当成音频直链交给 AVPlayer，报 -12847。
     *
     * 现在优先取上游自带的直链（免登录移动端接口就会返回 playUrl64/playUrl32）；
     * 没有直链才退回 /sound/{id} 让 audio() 去换 —— 但播放器层的出口闸会拦住它，不会再把网页当音频。
     */
    fun normalizeTrack(t: JsonObject, index: Int, sourceId: String): Episode {
        val trackId = AlbumNormalizer.lng(t, "trackId", "id")
        val direct = firstPlayableUrl(
            AlbumNormalizer.str(t, "playUrl64", "playUrl32", "playUrl", "src", "url", "downloadUrl")
        )
        return Episode(
            title = AlbumNormalizer.str(t, "title", "trackTitle"),
            url = direct ?: DetailRoutes.soundUrl(trackId),
            trackId = trackId,
            index = index,
            durationMs = AlbumNormalizer.lng(t, "duration", "length") * 1000L,   // 秒→毫秒（③）
            coverUrl = SearchRoutes.coverUrl(AlbumNormalizer.str(t, "cover", "coverLarge", "coverMiddle")),
        )
    }
}
