package com.local.audiobook.core.engine

/**
 * 免登录端点（Open Routes）
 *
 * 【来源】反编译 sources_by_agg.jar 的 XimalayaLogin 类时发现：
 * 源作者根本没走 webtk，而是用了另外三个域名的端点。
 *
 * 【实测结果 2026-11-23】
 *   搜索   search.ximalaya.com/front/v1            → 200, 40KB, 完整 docs
 *   详情   www.ximalaya.com/revision/album/v1/simple → 200, ret:200, 7.2KB
 *   曲目   www.ximalaya.com/revision/album/getTracksList → 200, 64 首
 *   曲目   mobwsa.ximalaya.com/mobile/playlist/album/page → 200, **含 playUrl64 直链**
 *   音频   aod.cos.tx.xmcdn.com/.../xxx.mp3       → 200（只要带 UA）
 *
 * 【关键结论】
 *   ① 不需要登录
 *   ② 不需要 webtk
 *   ③ 不需要过极验
 *   ④ 音频 CDN 只校验 User-Agent，不校验 Referer / 签名
 *
 * 这推翻了之前「必须登录才能用」的判断。
 */
object OpenRoutes {

    /** 搜索：返回 response.docs[] */
    const val SEARCH = "https://search.ximalaya.com/front/v1"

    /** 专辑详情：返回 data.albumPageMainInfo */
    const val ALBUM_SIMPLE = "https://www.ximalaya.com/revision/album/v1/simple"

    /** 曲目列表（PC）：返回 data.tracks[] */
    const val TRACKS_PC = "https://www.ximalaya.com/revision/album/getTracksList"

    /** 曲目列表（移动）：返回 list[] 且**含 playUrl64/playUrl32 直链** */
    const val TRACKS_MOBILE = "https://mobwsa.ximalaya.com/mobile/playlist/album/page"

    /** 曲目列表（移动备用）：返回 data.list[] */
    const val TRACKS_MOBILE2 = "https://mobile.ximalaya.com/mobile/v1/album/track"

    /** 分类列表 */
    const val CATEGORY = "https://www.ximalaya.com/revision/category/queryCategoryPageAlbums"

    /** 桌面 UA：搜索/详情端点需要它才不触发风控 */
    const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

    /**
     * 音频 CDN 必需的 UA（实测规律 2026-11-23）：
     *   "Mozilla/5.0"（太短）        → 403
     *   ""（curl 默认）              → 403
     *   完整 Chrome UA               → 200 ✓
     *   "ting_6.6.90(Galaxy,Android15)" → 200 ✓
     *
     * 规律：CDN 校验 UA 的「像不像真实客户端」，短 UA 会被拦。
     * Referer 反而是有害的（带上就 403）。
     */
    const val AUDIO_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // ---------- URL 构造 ----------

    fun search(keyword: String, page: Int, rows: Int = 20): String =
        SEARCH +
            "?core=album&kw=" + SearchRoutes.enc(keyword) +
            "&page=" + page +
            "&rows=" + rows +
            "&spellchecker=true&condition=relation&device=android&version=9.0.75"

    fun albumSimple(albumId: Long): String =
        ALBUM_SIMPLE + "?albumId=" + albumId

    fun tracksPc(albumId: Long, page: Int, size: Int = 30): String =
        TRACKS_PC + "?albumId=" + albumId + "&pageNum=" + page + "&pageSize=" + size

    fun tracksMobile(albumId: Long, page: Int, size: Int = 20): String =
        TRACKS_MOBILE + "?albumId=" + albumId + "&pageNum=" + page + "&pageSize=" + size

    fun tracksMobile2(albumId: Long, page: Int, size: Int = 10): String =
        TRACKS_MOBILE2 + "?albumId=" + albumId + "&pageId=" + page + "&pageSize=" + size + "&device=android"

    fun category(categoryId: Long, page: Int, size: Int = 20): String =
        CATEGORY + "?categoryId=" + categoryId + "&pageNum=" + page + "&pageSize=" + size + "&sort=1"

    /** 请求头：桌面端点用 */
    fun desktopHeaders(): Map<String, String> = mapOf(
        "User-Agent" to DESKTOP_UA,
        "Referer" to "https://www.ximalaya.com/",
        "Accept" to "application/json",
    )

    /**
     * 请求头：音频 CDN 只需要 UA，且**不能带 Referer**。
     * 实测：加 Referer 会变成 403。
     */
    fun audioHeaders(): Map<String, String> = mapOf(
        "User-Agent" to AUDIO_UA,
    )

    /** 判断是否音频 CDN 域名 */
    fun isAudioCdn(url: String): Boolean {
        val h = AudioUrlHeaders.hostOf(url) ?: return false
        return h == "xmcdn.com" || h.endsWith(".xmcdn.com") ||
            h == "xmcdn.cn" || h.endsWith(".xmcdn.cn")
    }
}
