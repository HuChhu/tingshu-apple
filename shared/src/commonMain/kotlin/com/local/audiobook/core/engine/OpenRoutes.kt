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

    /**
     * 搜索联想：返回 albumResultList[]（**单条**），结构与 front/v1 完全不同。
     *
     * 【2026-11-25 实测发现，很关键】front/v1 和 suggest 是**两个不同的池子**：
     *   · front/v1（网页搜索池）：免费优先。搜「在暴雪时分」返回 19 条，numFound=19 就封顶，
     *     VIP 专辑一条都没有。
     *   · suggest（官方运营联想池）：每个词只给 1 条，但给的是**官方主推那张** ——
     *     正是官方 App 搜索页第一名的那个。
     * 对照实测（同一时刻）：
     *   在暴雪时分 → 77615573（1510 万播放，边江工作室，VIP）
     *   三体       → 40121646（王明军单播）
     *   盗墓笔记   → 3544633（周建龙经典版）
     *   鬼吹灯     → 59325711（潘粤明影视原著）
     *   雪中悍刀行 → 2684034（大斌精品有声）
     *   诡秘之主   → 49808826（多人有声剧）
     * 全都是那条「用户觉得应该有、我们却搜不到」的官方扛把子。
     * 所以主搜之后必须再打一次 suggest 合并，否则用户永远看不到官方主推。
     */
    const val SUGGEST = "https://search.ximalaya.com/suggest"

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
     * 2026-11-25 复测修正：xmcdn 不校验 Referer（带不带都 206），真正的边界是缺 UA。
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

    fun suggest(keyword: String): String = SUGGEST + "?kw=" + SearchRoutes.enc(keyword)

    fun albumSimple(albumId: Long): String =
        ALBUM_SIMPLE + "?albumId=" + albumId

    fun tracksPc(albumId: Long, page: Int, size: Int = 30): String =
        TRACKS_PC + "?albumId=" + albumId + "&pageNum=" + page + "&pageSize=" + size

    fun tracksMobile(albumId: Long, page: Int, size: Int = 20): String =
        // 【P0 v1.4.9】mobwsa 的分页参数是 pageId，不是 pageNum。
        // 写错的话每页都返回第 1 页：1300 集的专辑只能拿到 20 集，而且这 20 集会被反复 addAll。
        TRACKS_MOBILE + "?albumId=" + albumId + "&pageId=" + page + "&pageSize=" + size

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
     * 请求头：音频 CDN 只发 UA。
     * 不带 Referer 是「够用、变量最少」，不是因为带了会挂。
     * 实测（2026-11-25 复测修正）：带不带 Referer 都是 206；缺 UA 才 403。
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
