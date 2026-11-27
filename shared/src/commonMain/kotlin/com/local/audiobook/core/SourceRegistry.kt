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
    /** 登录态提供者（P0-2：原来写死 null，登录版永远匿名） */
    private val cookieProvider: CookieProvider = object : CookieProvider {
        override suspend fun cookie(): String? = null
        override suspend fun refresh() {}
    },
) {
    // 【P1 2026-11-25】以前 38 个源共用**同一个** throttle 实例。
    // RequestThrottle.run() 是 mutex + 单飞闸门 —— 共用等于全局串行：
    //   · AggregateSearch 里 async+awaitAll 的「并发」实际完全排队；
    //   · 一个慢站（实测 aisongli/eshengda 要 45s）持锁期间，用户点任何别的源都在排队。
    // 实测 3 路并发 × 300ms 网络：共用一个 2318ms，各自一个 303ms，差 7.7 倍。
    // 现在按源分桶：**同一个源仍然 1 请求/秒**（防风控不能松），跨源互不阻塞。
    private val throttles = mutableMapOf<String, RequestThrottle>()
    private fun throttleFor(sourceId: String): RequestThrottle =
        throttles.getOrPut(sourceId) { RequestThrottle(minIntervalMs = 1_000L, clock = nowMs) }
    private val clock = nowMs

    // ---------- 原生源 ----------

    val ximalayaOpen = XimalayaOpenSource(fetcher, throttleFor("ximalaya-open"), cookieProvider = cookieProvider)
    val kuwo = KuwoSource(fetcher, throttleFor("kuwo"))
    val bilibili = BilibiliSource(fetcher, throttleFor("bilibili"))
    val qingting = QingtingSource(fetcher, throttleFor("qingting"), clock)
    val netease = NeteaseSource(fetcher, throttleFor("netease"))

    /** 登录版（需要 Cookie） */
    val ximalayaLogin = SearchEngine(
        fetcher = fetcher,
        throttle = throttleFor("ximalaya"),
        budget = WebSearchBudget(now = clock),
        nowMs = clock,
        cookieProvider = cookieProvider,
        sourceId = "ximalaya",
    )

    // ---------- 模板站 ----------

    /**
     * 模板站实例表。
     * P0（审计 2026-11-23）：原来这里 inline 装配，漏传 chapterPattern / chapterPrefix，
     * tingdada 的 /mp3/N-N-N.html 在真机上全变成 /play/N-N-N.html → detail 返回 0 章。
     * 现在统一走 TemplateSites.build()，CLI 与 App 只有一条装配路径。
     */
    private val templates: Map<String, TemplateTingSite> =
        TemplateSites.build(fetcher) { id -> throttleFor(id) }.associateBy { it.sourceId }

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

    /**
     * 音频提取结果（K/N 安全返回类型）。
     * 为什么需要：K/N 头文件明确「Other uncaught Kotlin exceptions are fatal」，
     * SourceErrors 继承 KotlinRuntimeException，直接抛给 Swift 会 fatal。
     * 所以 audio() 改为返回此类型，错误用 reason 字段表达。
     */
    data class BookDetailResult(
        val detail: BookDetail? = null,
        val reason: String? = null,
    )

    data class AudioResult(
        val audio: ExtractedAudio? = null,
        val reason: String? = null,
    )

    /** 全部源 */
    fun list(): List<SourceInfo> {
        val out = mutableListOf<SourceInfo>()
        // 【2026-11-27 用户要求】喜马拉雅**只保留一个源**。
        // 以前拆成「免登录」和「登录版」两个，用户看到两条同名条目，搜索结果里同一本书出现两次，
        // 还会因为走错通道导致「登录了会员却播不了」。
        //
        // 现在：只显示这一个，内部自动按登录态选通道（有 Cookie 走登录通道、无 Cookie 走公开接口）。
        // 旧数据里的 `ximalaya-open` id 仍然受理（见 search/bookDetail/audio 的 when 分支），
        // 这样历史记录、收藏、缓存的搜索结果都不会因为改名而失效。
        out.add(SourceInfo("ximalaya", "喜马拉雅", "登录后可听会员内容；未登录只能听免费集", "login"))
        out.add(SourceInfo("kuwo", "酷我听书", "免登录，返回多码率", "native"))
        out.add(SourceInfo("bilibili", "哔哩哔哩", "B站有声书，buvid3 可伪造", "native"))
        out.add(SourceInfo("qingting", "蜻蜓FM", "HMAC-MD5 签名已逆出", "native"))
        out.add(SourceInfo("netease", "网易云音乐", "走 Meting 代理", "native"))
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
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e   // 协程取消必须透传，否则切源/退出时旧请求继续跑
    } catch (e: Throwable) {
        SearchResult(emptyList(), 0, "error", page, e.message ?: "未知错误")
    }

    /**
     * 按源取详情。
     * 返回 BookDetailResult 而不是抛异常（K/N fatal 语义同上）。
     */
    suspend fun bookDetail(sourceId: String, bookUrl: String, loadEpisodes: Boolean,
                           loadFullPages: Boolean = true,
                           cancel: CancelToken = NeverCancelled): BookDetailResult = try {
        // cancel 说明见 Contract.kt 的 CancelToken：翻页循环每页检查一次，
        // 用户返回上一页后不再白翻 40 页、不再占着全局限速队列。
        // 【P0 2026-11-25】这里原来把 loadFullPages 写死成 false，全部源都只抓第一页。
        // 引擎侧 XimalayaOpenSource 是 `maxPages = if (loadFullPages) 60 else 1`，
        // 于是 App 上「在暴雪时分」显示 20 集、官方 App 是 67 集 —— 后 47 集根本没请求过。
        // 默认改成 true（详情页就是要全书）；真要只取一页的调用方显式传 false。
        val d = when (sourceId) {
            "ximalaya-open" -> ximalayaOpen.bookDetail(bookUrl, loadEpisodes, loadFullPages, cancel)
            "kuwo" -> kuwo.bookDetail(bookUrl, loadEpisodes, loadFullPages)
            "bilibili" -> bilibili.bookDetail(bookUrl, loadEpisodes, loadFullPages)
            "qingting" -> qingting.bookDetail(bookUrl, loadEpisodes, loadFullPages)
            "netease" -> netease.bookDetail(bookUrl, loadEpisodes, loadFullPages)
            "ximalaya" -> ximalayaLogin.bookDetail(bookUrl, loadEpisodes, loadFullPages, cancel)
            else -> templates[sourceId]?.bookDetail(bookUrl, loadEpisodes, loadFullPages)
                ?: return BookDetailResult(reason = unknownSource(sourceId))
        }
        BookDetailResult(detail = d)
    } catch (e: SourceErrors) {
        BookDetailResult(reason = describe(e))
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        BookDetailResult(reason = e.message ?: "未知错误")
    }

    /**
     * 按源取播放地址。
     * 返回 AudioResult 而不是抛异常：K/N 的 fatal 语义会让 Swift 侧直接崩溃。
     * 失败时 audio=null，reason=可读原因。
     */
    suspend fun audio(sourceId: String, url: String): AudioResult = try {
        val a = when (sourceId) {
            "ximalaya-open" -> ximalayaOpen.audioExtractor().extract(url)
            "kuwo" -> kuwo.audioExtractor().extract(url)
            "bilibili" -> bilibili.audioExtractor().extract(url)
            "qingting" -> qingting.audioExtractor().extract(url)
            "netease" -> netease.audioExtractor().extract(url)
            "ximalaya" -> ximalayaLogin.audioExtractor().extract(url)
            else -> templates[sourceId]?.audioExtractor()?.extract(url)
                ?: return AudioResult(reason = unknownSource(sourceId))
        }
        // 【P0 2026-11-24 出口总闸】任何源返回的地址都必须真的是音频。
        // 历史上 https://www.ximalaya.com/sound/{id}（网页）被原样交给 AVPlayer，
        // 报 -12847（kAudioFormatUnsupportedDataFormatError），用户只看到无意义的错误码。
        com.local.audiobook.core.engine.AudioUrlHeaders.requirePlayable(a.url, kindOf(sourceId) ?: sourceId)
        AudioResult(audio = a)
    } catch (e: SourceErrors) {
        AudioResult(reason = describe(e))
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        AudioResult(reason = e.message ?: "未知错误")
    }

    /** 模板站的分类浏览。失败返回空列表，不抛异常（K/N fatal 防护）。 */
    suspend fun categoryBooks(sourceId: String, catIndex: Int): List<Book> = try {
        templates[sourceId]?.categoryBooks(catIndex) ?: emptyList()
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Throwable) {
        emptyList()
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
        is SourceErrors.Vip -> e.reason
        is SourceErrors.Upstream -> "上游异常（HTTP " + e.status + "）"
    }
}
