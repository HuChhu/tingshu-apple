package com.local.audiobook.data.ximalaya

/**
 * 链接解析（从分享文本里提取 albumId / trackId）。纯函数，可单测。
 *
 * 支持的形式（移植自服务器桥的 parse-link，逻辑相同）：
 *  - https://www.ximalaya.com/album/38454623
 *  - https://www.ximalaya.com/sound/123456
 *  - https://mobile.ximalaya.com/album/xxx?albumId=123
 *  - 喜马拉雅 App 分享出来的一整段文字（含链接 + 推广语）
 *  - 直接粘贴纯数字（当作 albumId）
 *
 * 统一记录（T03）：本类是 albumId/trackId 解析的唯一实现；
 * 引擎 AudioUrlHeaders.parseTrackId 与 SearchEngine.parseAlbumId 已删除改用此处。
 */
object XimalayaLinkParser {

    private val ALBUM_PATH = Regex("/album/(\\d+)")
    private val SOUND_PATH = Regex("/sound/(\\d+)")
    private val ALBUM_QUERY = Regex("[?&]albumId=(\\d+)")
    private val TRACK_QUERY = Regex("[?&]trackId=(\\d+)")
    private val PURE_NUMBER = Regex("^\\s*(\\d{4,})\\s*$")

    data class Parsed(val albumId: Long?, val trackId: Long?) {
        val isEmpty: Boolean get() = albumId == null && trackId == null
    }

    fun parse(text: String?): Parsed {
        if (text.isNullOrBlank()) return Parsed(null, null)
        PURE_NUMBER.find(text)?.let { m ->
            return Parsed(m.groupValues[1].toLongOrNull(), null)
        }
        val album = ALBUM_PATH.find(text)?.groupValues?.get(1)?.toLongOrNull()
            ?: ALBUM_QUERY.find(text)?.groupValues?.get(1)?.toLongOrNull()
        val track = SOUND_PATH.find(text)?.groupValues?.get(1)?.toLongOrNull()
            ?: TRACK_QUERY.find(text)?.groupValues?.get(1)?.toLongOrNull()
        return Parsed(album, track)
    }

    /** 解析失败时给用户的提示 */
    const val HINT = "粘贴喜马拉雅分享链接，或直接输入专辑 ID"
}
