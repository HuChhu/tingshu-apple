package com.local.audiobook.core.engine

// 对拍基准：bridge api.py get_book_detail / get_audio_url 的 URL 模板
object DetailRoutes {
    // 详情/曲目共用模板：ts-{nowMs} 时间戳段对齐 bridge _now_ms()
    fun albumPage(albumId: Long, page: Int, pageSize: Int, nowMs: Long): String =
        SearchRoutes.MOBILE_BASE + "/mobile-album/album/page/ts-" + nowMs +
            "?albumId=" + albumId + "&page=" + page + "&pageSize=" + pageSize

    // 官方播放接口（级3 主路线）
    fun playAudio(trackId: Long): String =
        SearchRoutes.WEB_BASE + "/revision/play/v1/audio?ptype=1&id=" + trackId + "&xmSignType=1"

    fun soundUrl(trackId: Long): String = SearchRoutes.WEB_BASE + "/sound/" + trackId
}
