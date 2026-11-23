package com.local.audiobook.core

import com.local.audiobook.core.engine.BilibiliSource
import com.local.audiobook.core.engine.KuwoSource
import com.local.audiobook.core.engine.NeteaseSource
import com.local.audiobook.core.engine.QingtingSource
import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.engine.TemplateSites
import com.local.audiobook.core.engine.TemplateTingSite
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.core.engine.XimalayaOpenSource
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle

/**
 * 源的统一注册表（SourceRegistry）
 *
 * iOS 侧只需要跟这一个类打交道：
 *   list()                     → 全部可用源（名字 + id + 类型）
 *   search(sourceId, kw, pg)   → 按源搜索
 *   detail(sourceId, url)      → 按源详情
 *   audio(sourceId, url)       → 按源取播放地址
 *
 * 内部持有：
 *   - 5 个原生源（喜马拉雅免登录 / 酷我 / B站 / 蜻蜓 / 网易云）
 *   - 26 个模板站（TemplateSites 配置表）
 *   - 1 个登录版喜马拉雅（SearchEngine）
 */
class SourceRegistry(
    private val fetcher: JsonFetcher,
    private val nowMs: () -> Long = { 0L },
) {
    private val throttle = RequestThrottle(minIntervalMs = 1_000L, clock = nowMs)
    private val clock = nowMs

    // ---------- 原生源 ----------

    val ximalayaOpen = XimalayaOpenSource(fetcher, throttle)
    val kuwo = KuwoSource(fetcher, throttle)
    val bilibili = BilibiliSource(fetcher, throttle)
    val qingting = QingtingSource(fetcher, throttle, clock)
    val netease = NeteaseSource(fetcher, throttle)

    /** 登录版（需要 Cookie） */
    val ximalayaLogin = SearchEngine(
        fetcher = fetcher,
        throttle = throttle,
        budget = WebSearchBudget(now = clock),
        nowMs = clock,
        cookieProvider = object : CookieProvider {
            override suspend fun cookie(): String? = null
            override suspend fun refresh() {}
        },
    )

    // ---------- 模板站 ----------

    /**
     * 模板站实例表。
     * P0（审计 2026-11-23）：原来这里 inline 装配，漏传 chapterPattern / chapterPrefix，
     * tingdada 的 /mp3/N-N-N.html 在真机上全变成 /play/N-N-N.html → detail 返回 0 章。
     * 现在统一走 TemplateSites.build()，CLI 与 App 只有一条装配路径。
     */
    private val templates: Map<String, TemplateTingSite> =
        TemplateSites.build(fetcher, throttle).associateBy { it.sourceId }

    companion object {
        /** 原生源 id：不在 when 里写的都归模板站，写错 id 会静默掉到 templates[null] 再报"没有这个源" */
        val NATIVE_IDS = listOf("ximalaya-open", "kuwo", "bilibili", "qingting", "netease", "ximalaya")
    }

    /** 这个 id 是原生源还是模板站（UI 与排障用；未知 id 返回 null） */
    fun kindOf(sourceId: String): String? = when (sourceId) {
        in NATIVE_IDS -> if (sourceId == "ximalaya") "login" else "native"
        else -> if (templates.containsKey(sourceId)) "template" else null
    }

    // ---------- 统一接口 ----------

    /** 一个源的描述（给 UI 列表用） */
    data class SourceInfo(
        val id: String,
        val name: String,
        val desc: String,
        /** "native" = 原生实现，"template" = 模板站，"login" = 需登录 */
        val kind: String,
    )

    /** 全部源 */
    fun list(): List<SourceInfo> {
        val out = mutableListOf<SourceInfo>()
        out.add(SourceInfo("ximalaya-open", "喜马拉雅（免登录）", "官方公开接口，不需要登录取", "native"))
        out.add(SourceInfo("kuwo", "酷我听书", "免登录，返回多码率", "native"))
        out.add(SourceInfo("bilibili", "哔哩哔哩", "B站有声书，buvid3 可伪造", "native"))
        out.add(SourceInfo("qingting", "蜻蜓FM", "HMAC-MD5 签名已逆出", "native"))
        out.add(SourceInfo("netease", "网易云音乐", "走 Meting 代理", "native"))
        out.add(SourceInfo("ximalaya", "喜马拉雅（登录版）", "需登录，可听会员内容", "login"))
        // 模板站 id 必须和 NATIVE_IDS 不撞：撞了 list() 会出现两个同名条目，search() 也会静默走原生源
        for (cfg in TemplateSites.all) {
            if (cfg.key in NATIVE_IDS) continue
            out.add(SourceInfo(cfg.key, cfg.name, "模板站 " + cfg.base, "template"))
        }
        return out
    }

    /** 按源搜索。找不到源时返回空 + 提示。 */
    suspend fun search(sourceId: String, keywords: String, page: Int): SearchResult = try {
        when (sourceId) {
            "ximalaya-open" -> ximalayaOpen.search(keywords, page)
            "kuwo" -> kuwo.search(keywords, page)
            "bilibili" -> bilibili.search(keywords, page)
            "qingting" -> qingting.search(keywords, page)
            "netease" -> netease.search(keywords, page)
            "ximalaya" -> ximalayaLogin.search(keywords, page)
            else -> templates[sourceId]?.search(keywords, page)
                ?: SearchResult(emptyList(), 0, sourceId, page, unknownSource(sourceId))
        }
    } catch (e: SourceErrors) {
        SearchResult(emptyList(), 0, "error", page, describe(e))
    } catch (e: Throwable) {
        SearchResult(emptyList(), 0, "error", page, e.message ?: "未知错误")
    }

    /** 按源取详情 */
    suspend fun bookDetail(sourceId: String, bookUrl: String, loadEpisodes: Boolean): BookDetail {
        return when (sourceId) {
            "ximalaya-open" -> ximalayaOpen.bookDetail(bookUrl, loadEpisodes, false)
            "kuwo" -> kuwo.bookDetail(bookUrl, loadEpisodes, false)
            "bilibili" -> bilibili.bookDetail(bookUrl, loadEpisodes, false)
            "qingting" -> qingting.bookDetail(bookUrl, loadEpisodes, false)
            "netease" -> netease.bookDetail(bookUrl, loadEpisodes, false)
            "ximalaya" -> ximalayaLogin.bookDetail(bookUrl, loadEpisodes, false)
            else -> templates[sourceId]?.bookDetail(bookUrl, loadEpisodes, false)
                ?: throw SourceErrors.ParseFailed(unknownSource(sourceId))
        }
    }

    /** 按源取播放地址 */
    suspend fun audio(sourceId: String, url: String): ExtractedAudio {
        return when (sourceId) {
            "ximalaya-open" -> ximalayaOpen.audioExtractor().extract(url)
            "kuwo" -> kuwo.audioExtractor().extract(url)
            "bilibili" -> bilibili.audioExtractor().extract(url)
            "qingting" -> qingting.audioExtractor().extract(url)
            "netease" -> netease.audioExtractor().extract(url)
            "ximalaya" -> ximalayaLogin.audioExtractor().extract(url)
            else -> templates[sourceId]?.audioExtractor()?.extract(url)
                ?: throw SourceErrors.ParseFailed(unknownSource(sourceId))
        }
    }

    /** 模板站的分类浏览。失败时抛 SourceErrors，调用方转成提示。 */
    suspend fun categoryBooks(sourceId: String, catIndex: Int): List<Book> {
        return templates[sourceId]?.categoryBooks(catIndex)
            ?: throw SourceErrors.ParseFailed("没有这个源或不是模板站：" + sourceId)
    }

    /** 模板站的分类列表 */
    fun categories(sourceId: String): List<Pair<String, String>> {
        return TemplateSites.all.firstOrNull { it.key == sourceId }?.cats ?: emptyList()
    }

    /** 区分"原生源写错"和"模板站 key 不存在"，不然排障时看不出是哪种 */
    private fun unknownSource(sourceId: String): String =
        if (sourceId in NATIVE_IDS) "原生源未接入该动作：" + sourceId
        else "没有这个源：" + sourceId + "（可用模板站 " + TemplateSites.all.size + " 个）"

    private fun describe(e: SourceErrors): String = when (e) {
        is SourceErrors.NotFound -> "没有找到该资源"
        is SourceErrors.ParseFailed -> "解析失败：" + e.reason
        is SourceErrors.RateLimited -> "触发限流，稍后再试"
        is SourceErrors.Network -> "网络异常：" + e.reason
        is SourceErrors.Auth -> "需要登录"
        is SourceErrors.Upstream -> "上游异常（HTTP " + e.status + "）"
    }
}
