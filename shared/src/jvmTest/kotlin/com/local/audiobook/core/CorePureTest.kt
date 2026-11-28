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
import kotlinx.coroutines.launch
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

    // ---- 2026-11-25 P0：后端用 0 表示「没有到期时间」，不能换算成 1970-01-01 ----
    @Test fun zeroEpochIsNotADate() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"isVip":true,"vipExpireTime":0}"""
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("", com.local.audiobook.core.engine.VipStatusResolver.dateOf(o, "vipExpireTime"))
        val o2 = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"isVip":true,"vipExpireTime":"0"}"""
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("", com.local.audiobook.core.engine.VipStatusResolver.dateOf(o2, "vipExpireTime"))
        val o3 = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"isVip":true,"vipExpireTime":"2026-03-01"}"""
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("2026-03-01", com.local.audiobook.core.engine.VipStatusResolver.dateOf(o3, "vipExpireTime"))
        val o4 = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"isVip":true,"vipExpireTime":1772323200000}"""
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("2026-03-01", com.local.audiobook.core.engine.VipStatusResolver.dateOf(o4, "vipExpireTime"))
    }

    // ---- 2026-11-26 P0：runBulk 必须真并发（上一版 mutex 把 block 也锁住了） ----
    @Test fun runBulkAllowsConcurrentBlocks() = kotlinx.coroutines.runBlocking {
        // 间隔也归零：这条测的是「mutex 没把 block 锁住」，不是间隔行为。
        // （2026-11-28 教训：加了 250ms 批量间隔后，120ms 的 block 被间隔排队，峰值掉到 1 —— 测试误报）
        val t = com.local.audiobook.data.ximalaya.RequestThrottle(
            minIntervalMs = 0L, clock = { 0L }, bulkIntervalMs = 0L)
        val running = java.util.concurrent.atomic.AtomicInteger(0)
        val peak = java.util.concurrent.atomic.AtomicInteger(0)
        kotlinx.coroutines.coroutineScope {
            for (i in 1..6) {
                launch(kotlinx.coroutines.Dispatchers.Default) {
                    t.runBulk(concurrency = 3) {
                        val now = running.incrementAndGet()
                        peak.updateAndGet { p -> maxOf(p, now) }
                        Thread.sleep(120)
                        running.decrementAndGet()
                    }
                }
            }
        }
        assertTrue(peak.get() >= 2, "runBulk 必须能同时跑多个 block，实测峰值并发=" + peak.get())
    }
    // ---- 2026-11-26：放行规则的唯一实现（防止再出现「三处各写一遍、修一处漏两处」） ----
    @Test fun allowRetryKeepsTrackIdPlayable() {
        val locked = com.local.audiobook.core.Episode(
            title = "第21集", url = "", trackId = 666248221, index = 21,
            durationMs = 897000, coverUrl = "", playable = false, hint = "本集需要会员"
        )
        val r = com.local.audiobook.core.engine.TrackNormalizer.allowRetry(locked)
        assertTrue(r.playable, "带 trackId 的集必须放行，否则客户端通道永远走不到")
        assertEquals("", r.url, "url 可能残留网页地址，放行时必须清空")
        assertEquals(666248221L, r.trackId, "trackId 不能丢，extractor 靠它换地址")
        assertEquals("本集需要会员", r.hint, "hint 要保留，用于给用户解释")

        // 没有 trackId 的集：换不了地址，url 非空就原样保留（别把数据清掉）
        val noIdButUrl = locked.copy(trackId = 0L, url = "http://x/a.mp4")
        val kept = com.local.audiobook.core.engine.TrackNormalizer.allowRetry(noIdButUrl)
        assertEquals("http://x/a.mp4", kept.url, "没有 trackId 时 url 不能被清空")
        assertFalse(kept.playable, "没 trackId 也没法换地址，保持不可播")
        // 既没 trackId 又没 url：真的没救
        val dead = locked.copy(trackId = 0L, url = "")
        assertFalse(com.local.audiobook.core.engine.TrackNormalizer.allowRetry(dead).playable)

        // 本来就可播的不动
        val ok = locked.copy(url = "http://x/a.m4a", playable = true, hint = "")
        assertEquals(ok, com.local.audiobook.core.engine.TrackNormalizer.allowRetry(ok))
    }

    // ---- 2026-11-25：suggest 返回体结构（官方主推那一张） ----
    @Test fun suggestEnvelopeShape() {
        val j = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"albumResultNum":1,"albumResultList":[{"id":77615573,
               "keyword":"【高甜剧场】在暴雪时分","category":"有声书",
               "imgPath":"http://fdfs.xmcdn.com/x.jpeg"}],
               "queryResultNum":1,"queryResultList":[{"id":0,"keyword":"在暴雪时分"}]}"""
        ) as kotlinx.serialization.json.JsonObject
        val arr = j["albumResultList"] as kotlinx.serialization.json.JsonArray
        val first = arr.first() as kotlinx.serialization.json.JsonObject
        assertEquals("77615573", (first["id"] as kotlinx.serialization.json.JsonPrimitive).content)
        assertEquals("【高甜剧场】在暴雪时分", (first["keyword"] as kotlinx.serialization.json.JsonPrimitive).content)
    }

    // ---- suggest 与 front/v1 是两个池子：前者给官方主推，后者免费优先 ----
    @Test fun suggestUrlShape() {
        val u = com.local.audiobook.core.engine.OpenRoutes.suggest("在暴雪时分")
        assertTrue(u.startsWith("https://search.ximalaya.com/suggest?kw="), u)
        assertFalse(u.contains(" "), "关键词必须编码过：" + u)
    }

    // ---- 头部纪律：正例注入、错配必须原样 ----
    @Test fun headersHostMatchInjects() {
        // 2026-11-25 改：音频 CDN（xmcdn）只发 UA，绝不带 Referer（加了 403，见 OpenRoutes.audioHeaders）
        val cdn = AudioUrlHeaders.headersFor("https://a1.xmcdn.com/storages/x/y.mp3")
        assertEquals(1, cdn.size)
        assertTrue(cdn.containsKey("User-Agent"))
        assertFalse(cdn.containsKey("Referer"), "xmcdn 不许带 Referer：" + cdn)
        // 页面/接口域仍然要 Referer
        val page = AudioUrlHeaders.headersFor("https://mobile.ximalaya.com/x.json")
        assertEquals(2, page.size)
        assertTrue(page.containsKey("Referer"))
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
        // 2026-11-25 改：没直链的轨道 url 必须是**空串**，不允许再填 /sound/{id} 网页地址。
        // 旧断言锁的是 bug 本身 —— 正是它让 VIP 轨把网页喂给 AVPlayer，报「播不了」。
        assertEquals("", d.episodes[0].url)
        // 【2026-11-26 语义变更】bookDetail 现在会把「有 trackId 但没直链」的集统一放行（playable=true），
        // 因为会员集的地址只有 extractor 的客户端通道能给 —— 上层判死等于把那条路堵死。
        // 所以这里断言改成：hint 必须有（说明要会员），playable 已被放行。
        assertTrue(d.episodes[0].playable, "带 trackId 的轨道要放行给 extractor 去换地址")
        assertTrue(d.episodes[0].hint.isNotEmpty(), "必须带「要会员」的原因")
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
    // ---- 2026-11-25：playUrl64 为空串、playUrl32 有值 → 必须拿到 32 的直链（不能判死） ----
    @Test fun fallbackToPlayUrl32When64IsEmptyString() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":9,"title":"第9集","duration":10,
               "playUrl64":"","playUrl32":"https://aod.cos.tx.xmcdn.com/storages/x/32.mp3"}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(o, 1, "ximalaya-open")
        assertTrue(ep.playable, "有 playUrl32 就必须可播：" + ep.hint)
        assertTrue(ep.url.contains("32.mp3"), "必须回退到 playUrl32：" + ep.url)
    }

    // ---- 2026-11-25：AlbumNormalizer.str 跳过空串，取第一个非空 ----
    @Test fun albumNormalizerStrSkipsEmpty() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"a":"","b":"x","c":"y"}"""
        ) as kotlinx.serialization.json.JsonObject
        assertEquals("x", com.local.audiobook.core.engine.AlbumNormalizer.str(o, "a", "b", "c"))
        assertEquals("", com.local.audiobook.core.engine.AlbumNormalizer.str(o, "a"))
        assertEquals("x", com.local.audiobook.core.engine.AlbumNormalizer.str(o, "zzz", "b"))
    }

    // ---- P0 2026-11-25 回归：VIP/付费轨（playUrl 全空 + isPaid=true）必须标不可播并给原因 ----
    @Test fun vipTrackCarriesPayHintNotWebpage() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":671821892,"title":"第1集VIP","duration":1800,
               "playUrl64":"","playUrl32":"","isPaid":true,"price":0.2,
               "displayPrice":"0.20喜点/集","sampleDuration":90}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(o, 1, "ximalaya-open")
        assertEquals("", ep.url, "VIP 轨不许填网页地址")
        assertFalse(ep.playable)
        assertTrue(ep.hint.contains("会员"), "原因里必须说清要会员：" + ep.hint)
        // 2026-11-25 纠正：这批 VIP 专辑 priceTypeId=1（按集购买），会员不豁免。
        // 文案里不许再出现「已开通会员会自动走会员通道」这种误导。
        assertFalse(ep.hint.contains("自动走会员通道"), "不能暗示会员能解：" + ep.hint)
        assertTrue(ep.hint.contains("开通喜马拉雅会员"), "必须给出动作指引：" + ep.hint)
        // 2026-11-25：这批 VIP 专辑是「前 20 集免费 + 会员解锁」，不是按集购买，
        // 所以文案里不再出现价格，改为说清「需要会员 + 可试听时长」。
        assertTrue(ep.hint.contains("90"), "要带上试听时长：" + ep.hint)
        assertEquals(1800000L, ep.durationMs)
    }

    // ---- 免费轨：有直链时 playable=true 且 hint 为空 ----
    @Test fun freeTrackOmitsHint() {
        val o = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"trackId":2,"title":"第2集","duration":10,"playUrl64":"https://aod.cos.tx.xmcdn.com/b.m4a","isPaid":false}"""
        ) as kotlinx.serialization.json.JsonObject
        val ep = com.local.audiobook.core.engine.TrackNormalizer.normalizeTrack(o, 1, "ximalaya-open")
        assertTrue(ep.playable)
        assertEquals("", ep.hint, "能播就不要带提示")
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
        // 2026-11-25 改：以前 url 填 /sound/{id} 网页，靠 isPlayableAudio 判否兜底；
        // 现在直接留空，连「把网页当音频」这条路径都不存在了。
        assertEquals("", ep2.url, "只给 trackId 时 url 必须为空，不能是网页地址")
        assertFalse(ep2.playable)
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
    /**
     * 【2026-11-25 语义变更】旧行为：无 Cookie 直接抛 Auth，一个请求都不发。
     * 那时打的是 `revision/play/v1/audio`，匿名必 404，预检能省一次注定失败的请求。
     *
     * 现在打的是客户端通道 `mobile/v1/track/baseInfo` —— 它**匿名也能返回免费集的地址**
     * （实测：免费集 isAuthorized=true，playUrl64 给 redirect 链，302 到 audiopay CDN）。
     * 如果还保留「无 Cookie 直接抛」，未登录用户连前 20 集免费内容都听不了 —— 那是真 bug。
     *
     * 所以现在断言改成：无 Cookie **会发请求**，拿不到地址时按「需要登录」分类报错。
     */
    @Test fun extractWithoutCookieStillTriesClientChannel() = runBlocking {
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
        assertTrue(err != null, "没有路由时必须失败，不能假装成功")
        assertTrue(fake.calls >= 1, "客户端通道匿名也要打，否则免费集听不了")
        Unit
    }

}

/**
 * 【2026-11-28 回归】「已登录 = 一切都慢」的真凶是路由：登录用户用 id="ximalaya"，
 * 而它一直指向登录版 SearchEngine（每个请求 throttle.run：1 次/秒 + 单飞）。
 * 给 XimalayaOpenSource 做的所有提速对已登录用户完全没生效。
 * 这两条测试把路由钉住：主路必须是快的那个，拿不到再退回登录版。
 */
class LoggedInRoutingTest {
    private class RecordingFetcher(val answer: (String) -> FetchOutcome?) : JsonFetcher {
        val seen = java.util.concurrent.CopyOnWriteArrayList<String>()
        override suspend fun get(url: String, headers: Map<String, String>): FetchOutcome {
            seen.add(url)
            return answer(url) ?: FetchOutcome.Failed("NoRoute", url)
        }
    }

    private val frontJson = """
    {"response":{"docs":[
      {"id":88990011,"title":"在暴雪时分","nickname":"边江工作室",
       "cover_path":"http://imagev2.xmcdn.com/a.jpeg","intro":"","play":12000,"tracks":67,"is_finished":2}
    ],"numFound":1,"totalPage":1,"start":1}}
    """.trimIndent()

    ///
    /// 这条测试第一次跑就抓到一个真死锁：fetchOfficialPick 里写成了
    /// `throttle.run { throttle.runBulk { ... } }`，run() 全程持有 mutex、runBulk 再去拿同一把，
    /// 永远等下去 —— 所有第一页搜索都会卡死。所以这里套 10 秒超时：
    /// 再出这种问题要在 10 秒内红掉，而不是把 CI 挂死。
    @Test fun loggedInSearchGoesThroughFastPath() = runBlocking {
        kotlinx.coroutines.withTimeout(10_000L) {        val f = RecordingFetcher { u ->
            if (u.contains("search.ximalaya.com/front/v1")) FetchOutcome.Ok(200, frontJson) else null
        }
        val reg = com.local.audiobook.core.SourceRegistry(fetcher = f, nowMs = { 0L })
        val r = reg.search(sourceId = "ximalaya", keywords = "在暴雪时分", page = 1)
        assertTrue(r.books.isNotEmpty(), "登录态搜索必须有结果，hint=" + r.hint)
        assertTrue(f.seen.any { it.contains("search.ximalaya.com/suggest") },
                   "必须走快路（front + suggest 的官方主推合并）")
        assertTrue(f.seen.all { it.contains("search.ximalaya.com") },
                   "不得落到登录版的慢路，实际请求=" + f.seen)
        }
        Unit
    }

    /**
     * 【2026-11-28 P0 回归】引擎出口闸曾把喜马的中转口判成「网页」：先看域名（ximalaya.com 一票否决），
     * 根本轮不到中转口放行。结果是引擎连免费集都交不出地址，每一集只能靠网页嗅探。
     * 这条直接走 SourceRegistry.audio —— 钉的是「引擎真的能把免费集的地址交出来」。
     */
    @Test fun engineHandsOutFreeTrackThroughXimalayaRedirect() = runBlocking {
        val redirect = "http://mobile.ximalaya.com/mobile/redirect/free/play/665497021/1"
        val f = FakeFetcher().queue(
            "mobile.ximalaya.com/mobile/v1/track/baseInfo",
            """{"ret":0,"isFree":true,"isAuthorized":true,"playUrl64":"$redirect"}""",
        )
        val reg = com.local.audiobook.core.SourceRegistry(fetcher = f, nowMs = { 0L })
        val r = kotlinx.coroutines.withTimeout(10_000L) {
            reg.audio(sourceId = "ximalaya", url = "665497021")
        }
        assertTrue(r.reason == null, "免费集应当由引擎直接给出地址，实际 reason=" + r.reason)
        assertEquals(redirect, r.audio?.url, "必须原样交出中转口地址（由播放器去跟 302）")

        // 闸本身：中转口放行；真正的页面地址、接口地址仍然拦。
        assertTrue(com.local.audiobook.core.engine.AudioUrlHeaders.isPlayableAudioOrRelay(redirect), "中转口要放行")
        assertFalse(
            com.local.audiobook.core.engine.AudioUrlHeaders.isPlayableAudioOrRelay("https://www.ximalaya.com/sound/665497021"),
            "真正的页面地址仍然要拦",
        )
        assertFalse(
            com.local.audiobook.core.engine.AudioUrlHeaders.isPlayableAudioOrRelay(
                "https://mobile.ximalaya.com/mobile-playpage/track/v3/baseInfo/1?device=android&trackId=1"),
            "接口地址不是音频，要拦",
        )
        assertFalse(
            com.local.audiobook.core.engine.AudioUrlHeaders.isPlayableAudioOrRelay(
                "https://www.ximalaya.com/sound/665497021?next=/mobile/redirect/free/play/1/1"),
            "页面地址不能靠查询串里带个中转路径混过去",
        )
    }
    @Test fun detailFallsBackToLoginEngineWhenFastPathHasNothing() = runBlocking {
        kotlinx.coroutines.withTimeout(20_000L) {        // 快路（albumSimple / mobwsa）全部没路由 → 必须退回登录版的 albumPage
        val f = RecordingFetcher { u ->
            if (u.contains("mobile-album/album/page")) FetchOutcome.Ok(200, "{}") else null
        }
        val reg = com.local.audiobook.core.SourceRegistry(fetcher = f, nowMs = { 0L })
        reg.bookDetail(sourceId = "ximalaya",
                       bookUrl = "https://www.ximalaya.com/album/77615573", loadEpisodes = true)
        assertTrue(f.seen.any { it.contains("mobile-album/album/page") },
                   "快路拿不到时必须退回登录版，实际请求=" + f.seen)
        }
        Unit
    }
}
