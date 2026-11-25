package com.local.audiobook.core.engine

// 对拍基准：bridge api.py get_book_detail / get_audio_url 的 URL 模板
object DetailRoutes {
    // 详情/曲目共用模板：ts-{nowMs} 时间戳段对齐 bridge _now_ms()
    fun albumPage(albumId: Long, page: Int, pageSize: Int, nowMs: Long): String =
        SearchRoutes.MOBILE_BASE + "/mobile-album/album/page/ts-" + nowMs +
            "?albumId=" + albumId + "&page=" + page + "&pageSize=" + pageSize

    // 官方播放接口（级3 主路线）
    fun playAudio(trackId: Long): String =
        // 【2026-11-25】删掉 xmSignType=1 —— 从官方网页 JS 里挖出的真实 URL 只有 id 和 ptype，
        // 这个参数是我们自己加的，服务端不认，还可能干扰签名校验。
        SearchRoutes.WEB_BASE + "/revision/play/v1/audio?ptype=1&id=" + trackId

    fun soundUrl(trackId: Long): String = SearchRoutes.WEB_BASE + "/sound/" + trackId
}
