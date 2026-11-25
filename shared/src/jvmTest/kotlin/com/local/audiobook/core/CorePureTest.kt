package com.local.audiobook.core

import com.local.audiobook.core.engine.*
import com.local.audiobook.data.ximalaya.ErrorClassifier
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.data.ximalaya.XimalayaLinkParser
import com.local.audiobook.data.ximalaya.engine.XmSignEngine
import com.local.audiobook.data.ximalaya.engine.Crypto
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.*

class CorePureTest {

    // ---- 曲目索引数学（bridge baseIndex=(page-1)*pageSize 对齐） ----
    @Test fun trackIndexMath() {
        assertEquals(1, TrackNormalizer.indexAt(1, 30, 0))
        assertEquals(30, TrackNormalizer.indexAt(1, 30, 29))
        assertEquals(31, TrackNormalizer.indexAt(2, 30, 0))
        assertEquals(60, TrackNormalizer.indexAt(2, 30, 29))
    }

    @Test fun maxPageMath() {
        assertEquals(301L, TrackNormalizer.maxPage(9005, 30))   // ceil(9005/30) = 301
        assertEquals(1L, TrackNormalizer.maxPage(5, 30))
        assertEquals(0L, TrackNormalizer.maxPage(0, 30))
        assertEquals(0L, TrackNormalizer.maxPage(100, 0))
    }

    // ---- 头部纪律：正例注入、错配必须原样 ----
    @Test fun headersHostMatchInjects() {
        val h = AudioUrlHeaders.headersFor("https://a1.xmcdn.com/storages/x/y.jpeg")
        assertEquals(2, h.size)
        assertTrue(h.containsKey("User-Agent"))
        assertTrue(h.containsKey("Referer"))
        assertTrue(AudioUrlHeaders.isAudioHost("https://mobile.ximalaya.com/x"))
    }

    @Test fun headersHostMismatchMustStayEmpty() {
        assertTrue(AudioUrlHeaders.headersFor("https://cdn.example.com/a.mp3").isEmpty())
        // 伪装域：ximalaya.com 出现在路径里，不是 host
        assertTrue(AudioUrlHeaders.headersFor("https://github.com/ximalaya.com/a.mp3").isEmpty())
        // 后缀伪装：fakeximalaya.com 不是 .ximalaya.com 子域
        assertTrue(AudioUrlHeaders.headersFor("https://fakeximalaya.com/a.mp3").isEmpty())
    }

    // ---- 级1 直链判定 + trackId 解析 ----
    @Test fun directAudioAndTrackIdParse() {
        assertTrue(AudioUrlHeaders.isDirectAudio("https://a1.xmcdn.com/x/y.mp3?start=0"))
        assertTrue(AudioUrlHeaders.isDirectAudio("https://a.xmcdn.com/x.M4A"))
        assertFalse(AudioUrlHeaders.isDirectAudio("https://www.ximalaya.com/sound/123"))
        // trackId 解析唯一入口 = XimalayaLinkParser（/sound/、?trackId=）；裸数字按 LinkParser 语义=albumId
        assertEquals(123L, XimalayaLinkParser.parse("https://www.ximalaya.com/sound/123").trackId)
        assertEquals(789L, XimalayaLinkParser.parse("https://x.com/sound/789?from=share").trackId)
        assertNull(XimalayaLinkParser.parse("https://x.com/album/1").trackId)
    }

    @Test fun albumIdParse() {
        val e = SearchEngine(FakeFetcher(), RequestThrottle(clock = { 0 }), WebSearchBudget(now = { 0 }))
        assertEquals(9002L, e.parseAlbumId("https://www.ximalaya.com/album/9002"))
        assertEquals(4242L, e.parseAlbumId("4242"))   // 纯数字≥4位=albumId（LinkParser 约定）
        assertNull(e.parseAlbumId("https://www.ximalaya.com/sound/1"))
    }

    // ---- 播放响应回退链（src→url→playUrl，bridge _pick 对齐） ----
    @Test fun playResponseFallbackChain() {
        val src = Json.parseToJsonElement("{\"src\":\"https://a1.xmcdn.com/s.mp3\",\"url\":\"https://u\",\"playUrl\":\"https://p\"}") as kotlinx.serialization.json.JsonObject
        val urlOnly = Json.parseToJsonElement("{\"url\":\"https://u.mp3\"}") as kotlinx.serialization.json.JsonObject
        val playOnly = Json.parseToJsonElement("{\"playUrl\":\"https://p.mp3\"}") as kotlinx.serialization.json.JsonObject
        val none = Json.parseToJsonElement("{}") as kotlinx.serialization.json.JsonObject
        assertEquals("https://a1.xmcdn.com/s.mp3", AlbumNormalizer.str(src, "src", "url", "playUrl"))
        assertEquals("https://u.mp3", AlbumNormalizer.str(urlOnly, "src", "url", "playUrl"))
        assertEquals("https://p.mp3", AlbumNormalizer.str(playOnly, "src", "url", "playUrl"))
        assertEquals("", AlbumNormalizer.str(none, "src", "url", "playUrl"))
    }

    // ---- 分类：ret:50 保持桥语义 http_error（不新造分类），401/isNeedLogin→need_login ----
    @Test fun classifyBridgeAligned() {
        val r50 = ErrorClassifier.classifyJson(200, Json.parseToJsonElement("{\"ret\":50,\"msg\":\"请登录\"}") as kotlinx.serialization.json.JsonObject)
        assertEquals("http_error", r50.first)
        assertTrue(r50.second is SourceErrors.Upstream)
        val r401 = ErrorClassifier.classifyJson(200, Json.parseToJsonElement("{\"ret\":401,\"isNeedLogin\":true}") as kotlinx.serialization.json.JsonObject)
        assertEquals("need_login", r401.first)
        assertTrue(r401.second is SourceErrors.Auth)
    }

    // ---- CookieProvider：扁平 {name:value} → Cookie 串；只记字段名 ----
    @Test fun bridgeCookieProviderParsesFlatMap() = runBlocking {
        val f = Files.createTempFile("ck", ".json")
        Files.writeString(f, "{\"tok_a\":\"1\",\"sid_b\":\"2\"}")
        val p = BridgeCookieProvider(f.toString())
        assertEquals("tok_a=1; sid_b=2", p.cookie())
        assertEquals(listOf("sid_b", "tok_a"), p.loadedCookieNames())
        p.refresh()
        assertEquals("tok_a=1; sid_b=2", p.cookie())   // refresh 后重读同一文件
        Files.deleteIfExists(f)
        Unit
    }

    @Test fun cookieFileMissingMeansNull() = runBlocking {
        assertNull(BridgeCookieProvider("/nonexistent/ck.json").cookie())
        Unit
    }

    // ---- need_login → Auth 且不重试（fetcher 只被打一次） ----
    @Test fun needLoginThrowsAuthWithoutRetry() = runBlocking {
        val fake = FakeFetcher().queue("https://mobile.ximalaya.com/", "{\"ret\":401,\"isNeedLogin\":true}")
        val engine = SearchEngine(
            fetcher = fake,
            throttle = RequestThrottle(clock = { 0 }),
            budget = WebSearchBudget(now = { 0 }),
            nowMs = { 123L },
        )
        val err = runCatching { engine.bookDetail("4242", loadEpisodes = true, loadFullPages = false) }
            .exceptionOrNull()
        assertTrue(err is SourceErrors.Auth, "实际: " + err)
        // v1.4.9：现在先试一次免登录 mobwsa（拿不到就回退），
        // 所以 请求数 = 1（mobwsa）+ 1（登录版详情）。关键是登录版**只调一次**。
        assertEquals(2, fake.calls, "need_login 后不得重试登录版接口")
        Unit
    }

    // ---- 专辑不存在 → NotFound ----
    @Test fun missingAlbumThrowsNotFound() = runBlocking {
        val fake = FakeFetcher().queue("https://mobile.ximalaya.com/", "{\"ret\":200,\"data\":{\"album\":null,\"tracks\":[]}}")
        val engine = SearchEngine(fake, RequestThrottle(clock = { 0 }), WebSearchBudget(now = { 0 }), nowMs = { 1L })
        val err = runCatching { engine.bookDetail("4242", loadEpisodes = false, loadFullPages = false) }.exceptionOrNull()
        assertTrue(err is SourceErrors.NotFound, "实际: " + err)
        Unit
    }

    // ---- bookDetail 曲目索引连续性（跨页 31..34 用两页假数据验证） ----
    @Test fun detailPaginationIndexMath() = runBlocking {
        val fake = FakeFetcher()
            .queue("pageSize=1", "{\"ret\":200,\"data\":{\"album\":{\"id\":9001,\"title\":\"书\",\"tracks\":3}}}")
            .queue("page=1&pageSize=30", "{\"ret\":200,\"data\":{\"tracks\":{\"list\":[{\"id\":1,\"title\":\"第1集\",\"duration\":100},{\"id\":2,\"title\":\"第2集\",\"duration\":200}],\"totalCount\":3,\"maxPageId\":2}}}")
            .queue("page=2&pageSize=30", "{\"ret\":200,\"data\":{\"tracks\":{\"list\":[{\"id\":3,\"title\":\"第3集\",\"duration\":300}],\"totalCount\":3,\"maxPageId\":2}}}")
        val engine = SearchEngine(fake, RequestThrottle(clock = { 0 }), WebSearchBudget(now = { 0 }), nowMs = { 9L })
        val d = engine.bookDetail("9001", loadEpisodes = true, loadFullPages = true)
        assertEquals(3, d.episodes.size)
        assertEquals(1, d.episodes[0].index)
        assertEquals(2, d.episodes[1].index)
        assertEquals(31, d.episodes[2].index)   // 第2页首条 = (2-1)*30+0+1 = 31（数学事实，与 bridge baseIndex 一致）
        assertEquals(100000L, d.episodes[0].durationMs)   // duration 秒→毫秒（修正③）
        assertEquals("https://www.ximalaya.com/sound/1", d.episodes[0].url)
        Unit
    }

    // ---- 曲目信封结构（live 实锤：tracks.list + totalCount + maxPageId） ----
    @Test fun trackEnvelopeShape() {
        val json = Json.parseToJsonElement("{\"tracks\":{\"list\":[{\"trackId\":31,\"title\":\"第31集\",\"duration\":310,\"coverLarge\":\"http://x/c.jpeg\"},{\"trackId\":32,\"title\":\"第32集\"}],\"totalCount\":9005,\"maxPageId\":94}}") as kotlinx.serialization.json.JsonObject
        val tp = TrackExtractor.fromDetail(json, 2, 30, "src")
        assertEquals(2, tp.episodes.size)
        assertEquals(31, tp.episodes[0].index)          // page=2 首条
        assertEquals(9005L, tp.totalCount)
        assertEquals(94L, tp.maxPageId)
        assertEquals(310000L, tp.episodes[0].durationMs)
        assertEquals("https://<cdn>/http://x/c.jpeg".replace("https://<cdn>/http://x/c.jpeg", "http://x/c.jpeg"), tp.episodes[0].coverUrl)  // 已含 scheme 不拼 CDN
        // 防御形态：裸列表
        val bare = Json.parseToJsonElement("{\"tracks\":[{\"id\":5,\"title\":\"第5集\"}]}") as kotlinx.serialization.json.JsonObject
        val tp2 = TrackExtractor.fromDetail(bare, 1, 30, "src")
        assertEquals(1, tp2.episodes.size)
        assertEquals(5L, tp2.episodes[0].trackId)
        Unit
    }
    // ---- 2026-11-24 P0 回归：网页地址绝不能被当成音频直链返回 ----
    @Test fun webpageUrlIsNeverPlayableAudio() {
        // 真机现场：https://www.ximalaya.com/sound/{id} 这个网页被当音频播了，AVPlayer 报 -12847
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/sound/1011694179"))
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://m.ximalaya.com/sound/1011694179"))
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/album/41682166"))
        // 门户域名下即便后缀像音频也不许过（防 /sound/1.html?x=.mp3 这类伪造）
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/a.mp3"))
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.ximalaya.com/x/1.html?f=a.mp3"))
        // 其它门户同理
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://www.kuwo.cn/play_detail/123"))
        assertFalse(AudioUrlHeaders.isPlayableAudio("https://music.163.com/song?id=1"))
        // 真直链要放行
        assertTrue(AudioUrlHeaders.isPlayableAudio("https://aod.cos.tx.xmcdn.com/storages/x/1.m4a"))
        assertTrue(AudioUrlHeaders.isPlayableAudio("http://aod.cos.tx.xmcdn.com/storages/x/1.mp3"))
        assertTrue(AudioUrlHeaders.isPlayableAudio("https://files.vbus.cc/u/1.mp3?expires=1&md5=2"))
        // 非 http 协议不算
        assertFalse(AudioUrlHeaders.isPlayableAudio("/sound/123"))
    }

    @Test fun episodesCarryDirectAudioNotWebpage() {
        // 上游给了 playUrl64 → Episode.url 必须是直链
        val t = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":671821892,"title":"第1集","duration":45,
               "playUrl64":"http://aod.cos.tx.xmcdn.com/storages/x/1.mp3",
               "playUrl32":"http://aod.cos.tx.xmcdn.com/storages/x/2.mp3"}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(t, 1, "ximalaya")
        assertEquals("http://aod.cos.tx.xmcdn.com/storages/x/1.mp3", ep.url)

        // 上游只给 trackId 时退回 /sound/{id}（让 audio() 去换），但播放器出口闸会拦住它 ——
        // 这里锁住「拿到的不是直链」这个事实，防止有人再把网页当音频播
        val t2 = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":1011694179,"title":"第2集","duration":60}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep2 = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(t2, 2, "ximalaya")
        assertFalse(
            AudioUrlHeaders.isPlayableAudio(ep2.url),
            "只给 trackId 时 url 是网页地址，必须被 isPlayableAudio 判否（不能直接交给播放器）"
        )
    }

    // ---- P0 回归：曲目列表富化后，Episode.url 不能是门户网页 ——
    @Test fun trackNormalizerPrefersPlayUrlOverSoundPage() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":1,"title":"a","duration":10,"playUrl64":"https://aod.cos.tx.xmcdn.com/a.m4a"}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(o, 1, "ximalaya-open")
        assertTrue(ep.url.contains("aod.cos.tx.xmcdn.com"), "有 playUrl64 就必须用它：" + ep.url)
        assertTrue(AudioUrlHeaders.isPlayableAudio(ep.url), "直接链应可播")
    }

    // ---- P0 回归：免登录曲目列表（list 外层）能被解析且带直链 ----
    @Test fun openTrackListEnvelopeParsed() {
        val root = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"ret":0,"totalCount":2,"maxPageId":1,"list":[
                 {"trackId":11,"title":"第1集","duration":45,"playUrl64":"http://aod.cos.tx.xmcdn.com/1.mp3"},
                 {"trackId":12,"title":"第2集","duration":50,"playUrl32":"http://aod.cos.tx.xmcdn.com/2.mp3"}
               ]}"""
        ) as kotlinx.serialization.json.JsonObject
        val tp = com.local.audiobook.core.engine.TrackExtractor.fromOpenList(root, 1, 20, "ximalaya-open")
        assertEquals(2, tp.episodes.size)
        assertEquals(2L, tp.totalCount)
        assertEquals(1L, tp.maxPageId)
        assertTrue(tp.episodes.all { AudioUrlHeaders.isPlayableAudio(it.url) }, "免登录曲目应全是直链")
    }

    // ---- P0 回归：Hit 构造时就拒绝网页地址 ----
    @Test fun multistepHitRejectsWebpageUrl() {
        var threw = false
        try {
            com.local.audiobook.core.engine.MultistepAudioExtractor.Hit(
                "https://www.ximalaya.com/sound/1011694179",
                com.local.audiobook.core.engine.MultistepAudioExtractor.Level.Json,
            )
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw, "网页地址不能装进 Hit")
        // 正常直链不应受影响
        val ok = com.local.audiobook.core.engine.MultistepAudioExtractor.Hit(
            "https://aod.cos.tx.xmcdn.com/a.mp3",
            com.local.audiobook.core.engine.MultistepAudioExtractor.Level.Html,
        )
        assertTrue(ok.url.endsWith(".mp3"))
    }
}

// 可编程假 fetcher：按 URL 片段匹配返回预置响应；计数调用次数
class FakeFetcher : JsonFetcher {
    private val routes = ArrayList<Pair<String, String>>()
    var calls = 0; private set

    fun queue(urlPart: String, body: String): FakeFetcher { routes.add(urlPart to body); return this }

    override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome {
        calls++
        val hit = routes.firstOrNull { url.contains(it.first) }
        return if (hit != null) FetchOutcome.Ok(200, hit.second)
        else FetchOutcome.Failed("NoRoute", url)
    }
}


// ==== T03 迁移新增单测 ====

class MigrationTest {

    // ---- 统一分类器：M1/M2 矩阵 5/5 回归（classifyJson 面） ----
    @Test fun unifiedClassifierMatrix() {
        fun o(s: String) = Json.parseToJsonElement(s) as kotlinx.serialization.json.JsonObject
        // 1 risk
        val risk = ErrorClassifier.classifyJson(200, o("{\"ret\":200,\"data\":{\"reason\":\"risk invalid\",\"riskLevel\":5}}"))
        assertEquals("risk" to true, risk.first to (risk.second is SourceErrors.RateLimited))
        // 2 need_login
        val nl = ErrorClassifier.classifyJson(200, o("{\"ret\":401,\"isNeedLogin\":true}"))
        assertEquals("need_login" to true, nl.first to (nl.second is SourceErrors.Auth))
        // 3 http_error ret:50（bridge 语义：保持 http_error 不新造分类）
        val r50 = ErrorClassifier.classifyJson(200, o("{\"ret\":50,\"msg\":\"请登录\"}"))
        assertEquals("http_error" to 50, r50.first to ((r50.second as? SourceErrors.Upstream)?.status))
        // 4 http_error ret:924 下架
        val r924 = ErrorClassifier.classifyJson(200, o("{\"msg\":\"当前内容已下架\",\"ret\":924}"))
        assertEquals("http_error" to 924, r924.first to ((r924.second as? SourceErrors.Upstream)?.status))
        // 5 ok
        val ok = ErrorClassifier.classifyJson(200, o("{\"ret\":200,\"data\":{}}"))
        assertEquals("ok" to null, ok.first to ok.second)
    }

    // ---- Crypto：RFC 向量 + python hashlib 对拍值 ----
    @Test fun cryptoRfcVectors() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", Crypto.md5Hex(""))
        assertEquals("900150983cd24fb0d6963f7d28e17f72", Crypto.md5Hex("abc"))
        assertEquals("c3b7f474eea166854de1eb0d51037d99", Crypto.md5Hex("xmly/revision/play/v1/audio"))
        assertEquals("17fe924b5637e6062ac51ddc5921e8728be01e77", Crypto.hmacSha1Hex("Hi There", "xxxxxxxx"))   // RFC 2104 案例1（8×x key）
        assertEquals("52d5414ade3755ca8c37168170b862b706770a8f", Crypto.hmacSha1Hex("/revision/play/v1/audio", "xmly"))
    }

    // ---- XmSignEngine：确定性 + 结构 ----
    @Test fun signEngineDeterministicAndShaped() {
        val cookies = mapOf("1&_token" to "tok123")
        val s1 = XmSignEngine.sign("/revision/play/v1/audio", mapOf("id" to "1", "ptype" to "1"), cookies, 1_700_000_000_000L)
        val s2 = XmSignEngine.sign("/revision/play/v1/audio", mapOf("id" to "1", "ptype" to "1"), cookies, 1_700_000_000_000L)
        assertEquals(s1, s2)
        val sig = s1[XmSignEngine.PARAM_SIGN]!!
        assertTrue(sig.startsWith("1700000000000~"), sig)
        assertEquals(2, sig.split("~").size - 1)
        assertEquals(16, sig.split("~")[1].length)
        assertEquals(16, sig.split("~")[2].length)
        // 无 token 时密钥回落 SIGN_PREFIX
        val s3 = XmSignEngine.sign("/x", emptyMap(), emptyMap(), 1L)
        assertEquals(s3, XmSignEngine.sign("/x", emptyMap(), emptyMap(), 1L))
    }

    // ---- XimalayaLinkParser：唯一解析器 ----
    @Test fun linkParserCovers() {
        assertEquals(9003L, XimalayaLinkParser.parse("https://www.ximalaya.com/album/9003").albumId)
        assertEquals(123456L, XimalayaLinkParser.parse("https://www.ximalaya.com/sound/123456").trackId)
        assertEquals(123L, XimalayaLinkParser.parse("https://mobile.ximalaya.com/album/xxx?albumId=123").albumId)
        assertEquals(999L, XimalayaLinkParser.parse("看这个 https://www.ximalaya.com/sound/999?x=1 超好听").trackId)
        assertEquals(9001L, XimalayaLinkParser.parse("9001").albumId)
        assertTrue(XimalayaLinkParser.parse("没有链接的文本").isEmpty)
    }

    // ---- 统一 Throttle：waitMs/markRequest 时钟注入 + run{} 串行 ----
    @Test fun unifiedThrottleClockInjection() = runBlocking {
        var t = 0L
        val th = com.local.audiobook.data.ximalaya.RequestThrottle(minIntervalMs = 1_000, clock = { t })
        assertEquals(0L, th.waitMs())          // 首请求免等待
        th.markRequest()
        assertEquals(1_000L, th.waitMs())      // 刚发完 → 等 1000
        t = 600
        assertEquals(400L, th.waitMs())        // 600ms 过去 → 还差 400
        t = 1_000
        assertEquals(0L, th.waitMs())
        assertTrue(th.tryAcquire())
        assertFalse(th.tryAcquire())           // 并发 1
        th.release()
        assertTrue(th.tryAcquire())
        th.release()
        var x = 0
        th.run { x = 1 }
        assertEquals(1, x)
        Unit
    }
}


class AuthPrecheckTest {
    @Test fun extractWithoutCookieThrowsAuthAndSavesTheRequest() = runBlocking {
        val fake = FakeFetcher()   // 不预置任何路由：若发了请求会得 Failed(NoRoute) 而非 Auth
        val x = com.local.audiobook.core.engine.XimalayaAudioExtractor(
            fetcher = fake,
            throttle = RequestThrottle(clock = { 0L }),
            cookieProvider = object : com.local.audiobook.core.CookieProvider {
                override suspend fun cookie(): String? = null
                override suspend fun refresh() {}
            },
        )
        val err = runCatching { x.extract("9004") }.exceptionOrNull()
        assertTrue(err is SourceErrors.Auth, "实际: " + err)
        assertEquals(0, fake.calls, "预检命中不得发请求（桥 has_login 同款语义）")
        Unit
    }

}
