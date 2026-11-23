package com.local.audiobook.core.engine

import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle

/**
 * 模板站配置表（Template Site Registry）
 *
 * 【来源】从 14 个 jar 的 XmTingSite 子类构造函数逐字节提取。
 *
 * 【实测 2026-11-23】逐个站探活 + 探测书籍链接模式，结果是：
 *   25 个站存活，书籍链接只有 8 种模式：
 *     /ting/N.html       9 个站
 *     /tingshu/N.html    5 个站
 *     /mp3/N.html        4 个站
 *     /show/N.html       Qmtsw
 *     /book/N.html       AiNaiCha
 *     /books/N.html      TingDaDa
 *     /huanting/N.html   InetOver
 *     /xiu/N.html        MalaXiu
 *
 * 【意义】26 个存活站点 = 1 个引擎 + 25 条配置。
 */
object TemplateSites {

    data class SiteConfig(
        val key: String,
        val name: String,
        val base: String,
        val bookHrefPattern: String,
        val cats: List<Pair<String, String>>,
        /**
         * 章节链接正则（默认 /play/N-N-N.html）。
         * 实测发现不同站差异很大：
         *   tingdada 用 /mp3/N-N-N.html
         *   ytysxs   章节就是 /N.html
         * 之前这个参数没暴露，导致这几站 detail 返回 0 章。
         */
        val chapterPattern: String = "/play/(\\d+)-(\\d+)-(\\d+)\\.html",
        /** 章节 URL 前缀（有的站章节不在 /play/ 下，要整段拼接） */
        val chapterPrefix: String = "/play/",
        /** 章节来源：Html（默认，正则抓链接）/ Playlist（audioigniter JSON）/ Json（数据接口） */
        val chapterMode: TemplateTingSite.ChapterMode = TemplateTingSite.ChapterMode.Html,
        val jsonApiPattern: String = "",
        val jsonListKey: String = "data",
        val jsonUrlKey: String = "url",
        val jsonAudioKey: String = "",
        val jsonTitleKey: String = "title",
        val jsonCoverKey: String = "",
        /** HtmlPages 模式：第 N 页 URL 模板，{url}=首章 URL，{page}=页码 */
        val htmlPagePattern: String = "{url}/{page}",
        val htmlMaxPages: Int = 40,
        /** HtmlPages 第二页的 {page} 值（vbus=2；yuetingba=按集数偏移 40） */
        val htmlPageStart: Int = 2,
        val htmlPageStep: Int = 1,
        /** 章节 URL 取哪个捕获组的整段路径（-1 = 整个匹配就是 URL；0 = 默认 3 段拼接） */
        val chapterPathGroup: Int = 0,
        /** 播放接口（POST 表单换音频），ting15 用 /?s=api-getneoplay */
        val audioApiPattern: String = "",
        /** 播放接口（GET，响应正文 = 音频 URL），{url}/{id} 占位 */
        val audioApiUrlPattern: String = "",
    )

    val all: List<SiteConfig> = listOf(
        SiteConfig(
            key = "ainaicha",
            name = "AiNaiCha",
            base = "https://www.ainaicha.com",
            bookHrefPattern = "/book/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.ainaicha.com/ai/251.html", "武侠" to "https://www.ainaicha.com/ai/252.html",
                "悬疑" to "https://www.ainaicha.com/ai/253.html", "历史" to "https://www.ainaicha.com/ai/254.html",
                "军事" to "https://www.ainaicha.com/ai/255.html", "评书" to "https://www.ainaicha.com/ai/256.html",
            ),
        ),
        SiteConfig(
            key = "aisongli",
            name = "AiSongLi",
            base = "https://www.aisongli.com",
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "首页" to "https://www.aisongli.com/ai/1.html",
            ),
        ),
        SiteConfig(
            key = "dengdeng",
            name = "DengDeng",
            base = "https://www.deng-deng.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.deng-deng.com/dengdeng/5201.html", "武侠" to "https://www.deng-deng.com/dengdeng/5202.html",
                "悬疑" to "https://www.deng-deng.com/dengdeng/5203.html", "历史" to "https://www.deng-deng.com/dengdeng/5204.html",
                "军事" to "https://www.deng-deng.com/dengdeng/5205.html", "评书" to "https://www.deng-deng.com/dengdeng/5206.html",
            ),
        ),
        SiteConfig(
            key = "dndq888",
            name = "DndQ888",
            base = "https://www.dndq888.com",
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.dndq888.com/dndq/1.html", "武侠" to "https://www.dndq888.com/dndq/2.html",
                "悬疑" to "https://www.dndq888.com/dndq/3.html", "历史" to "https://www.dndq888.com/dndq/4.html",
                "军事" to "https://www.dndq888.com/dndq/5.html", "评书" to "https://www.dndq888.com/dndq/6.html",
            ),
        ),
        SiteConfig(
            key = "ebiaoyan",
            name = "EBiaoYan",
            base = "https://www.ebiaoyan.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "首页" to "https://www.ebiaoyan.com/list/1531.html",
            ),
        ),
        SiteConfig(
            key = "eshengda",
            name = "EShengDa",
            base = "https://www.eshengda.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.eshengda.com/list/1.html", "武侠" to "https://www.eshengda.com/list/2.html",
                "悬疑" to "https://www.eshengda.com/list/3.html", "历史" to "https://www.eshengda.com/list/4.html",
                "军事" to "https://www.eshengda.com/list/5.html", "评书" to "https://www.eshengda.com/list/6.html",
            ),
        ),
        SiteConfig(
            key = "gushiya",
            name = "GuShiYa",
            base = "https://www.gushiya.com",
            // 实测 2026-11-23：书页仍是 /tingshu/N.html，但分类页从 /tingshu/N.html 迁到 /ya/N.html，
            // 首页只剩 6 个 /tingshu/ 链接（推荐位），旧配置的 /tingshu/1581.html 是 404。
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.gushiya.com/ya/1581.html", "武侠" to "https://www.gushiya.com/ya/1582.html",
                "悬疑" to "https://www.gushiya.com/ya/1583.html", "历史" to "https://www.gushiya.com/ya/1584.html",
                "军事" to "https://www.gushiya.com/ya/1585.html", "评书" to "https://www.gushiya.com/ya/1586.html",
                "相声小品" to "https://www.gushiya.com/ya/1587.html", "商业财经" to "https://www.gushiya.com/ya/1589.html",
            ),
        ),
        SiteConfig(
            key = "hongmujie",
            name = "HongMuJie",
            base = "https://www.hongmujie.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.hongmujie.com/mujie/1831.html", "武侠" to "https://www.hongmujie.com/mujie/1832.html",
                "悬疑" to "https://www.hongmujie.com/mujie/1833.html", "历史" to "https://www.hongmujie.com/mujie/1834.html",
                "军事" to "https://www.hongmujie.com/mujie/1835.html", "评书" to "https://www.hongmujie.com/mujie/1836.html",
            ),
        ),
        SiteConfig(
            key = "ihonghai",
            name = "IHongHai",
            base = "https://www.ihonghai.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "首页" to "https://www.ihonghai.com/",
            ),
        ),
        SiteConfig(
            key = "ilehao",
            name = "ILeHao",
            base = "https://www.ilehao.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.ilehao.com/lehao/1101.html", "武侠" to "https://www.ilehao.com/lehao/1102.html",
                "悬疑" to "https://www.ilehao.com/lehao/1103.html", "历史" to "https://www.ilehao.com/lehao/1104.html",
                "军事" to "https://www.ilehao.com/lehao/1105.html", "评书" to "https://www.ilehao.com/lehao/1106.html",
            ),
        ),
        SiteConfig(
            key = "inetover",
            name = "InetOver",
            base = "http://inetover.com",
            bookHrefPattern = "/huanting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "http://inetover.com/list/261.html", "武侠" to "http://inetover.com/list/262.html",
                "悬疑" to "http://inetover.com/list/263.html", "历史" to "http://inetover.com/list/264.html",
                "军事" to "http://inetover.com/list/265.html", "评书" to "http://inetover.com/list/266.html",
            ),
        ),
        SiteConfig(
            key = "kmbas",
            name = "KMBas",
            base = "https://kmbas.com",
            bookHrefPattern = "/mp3/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://kmbas.com/as/1101.html", "武侠" to "https://kmbas.com/as/1102.html",
                "悬疑" to "https://kmbas.com/as/1103.html", "历史" to "https://kmbas.com/as/1104.html",
                "军事" to "https://kmbas.com/as/1105.html", "评书" to "https://kmbas.com/as/1106.html",
            ),
        ),
        SiteConfig(
            key = "malaxiu",
            name = "MalaXiu",
            base = "https://www.malaxiu.com",
            bookHrefPattern = "/xiu/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.malaxiu.com/mala/1.html", "武侠" to "https://www.malaxiu.com/mala/2.html",
                "悬疑" to "https://www.malaxiu.com/mala/3.html", "历史" to "https://www.malaxiu.com/mala/4.html",
                "军事" to "https://www.malaxiu.com/mala/5.html", "评书" to "https://www.malaxiu.com/mala/6.html",
            ),
        ),
        SiteConfig(
            key = "mimiting",
            name = "MiMiTing",
            base = "https://www.mimiting.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.mimiting.com/mimi/1.html", "武侠" to "https://www.mimiting.com/mimi/2.html",
                "悬疑" to "https://www.mimiting.com/mimi/3.html", "历史" to "https://www.mimiting.com/mimi/4.html",
                "军事" to "https://www.mimiting.com/mimi/5.html", "评书" to "https://www.mimiting.com/mimi/6.html",
            ),
        ),
        SiteConfig(
            key = "music189",
            name = "Music189",
            base = "https://www.189music.com",
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.189music.com/list/1891.html", "武侠" to "https://www.189music.com/list/1892.html",
                "悬疑" to "https://www.189music.com/list/1893.html", "历史" to "https://www.189music.com/list/1894.html",
                "军事" to "https://www.189music.com/list/1895.html", "评书" to "https://www.189music.com/list/1896.html",
            ),
        ),
        SiteConfig(
            key = "picfxapp",
            name = "PicFxApp",
            base = "https://picfxapp.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "首页" to "https://picfxapp.com/",
            ),
        ),
        SiteConfig(
            key = "qmtsw",
            name = "Qmtsw",
            base = "https://www.qmtsw.com",
            bookHrefPattern = "/show/(\\d+)\\.html",
            cats = listOf(
                "玄幻" to "https://www.qmtsw.com/book/1.html", "言情" to "https://www.qmtsw.com/book/2.html",
                "都市" to "https://www.qmtsw.com/book/3.html", "武侠" to "https://www.qmtsw.com/book/7.html",
                "历史" to "https://www.qmtsw.com/book/8.html", "军事" to "https://www.qmtsw.com/book/9.html",
            ),
        ),
        SiteConfig(
            key = "tianxiatingshu",
            name = "TianXiaTingShu",
            base = "http://www.seotianxia.com",
            bookHrefPattern = "/mp3/(\\d+)\\.html",
            cats = listOf(
                "言情小说" to "http://www.seotianxia.com/tianxia/1.html", "武侠小说" to "http://www.seotianxia.com/tianxia/2.html",
                "悬疑小说" to "http://www.seotianxia.com/tianxia/3.html", "历史小说" to "http://www.seotianxia.com/tianxia/4.html",
                "军事小说" to "http://www.seotianxia.com/tianxia/5.html", "评书小说" to "http://www.seotianxia.com/tianxia/6.html",
            ),
        ),
        SiteConfig(
            key = "ting78",
            name = "Ting78",
            base = "https://www.ting78.com",
            bookHrefPattern = "/mp3/(\\d+)\\.html",
            cats = listOf(
                "玄幻" to "https://www.ting78.com/books/1.html", "言情" to "https://www.ting78.com/books/2.html",
                "都市" to "https://www.ting78.com/books/3.html", "恐怖" to "https://www.ting78.com/books/4.html",
                "惊悚" to "https://www.ting78.com/books/5.html", "推理" to "https://www.ting78.com/books/6.html",
            ),
        ),
        SiteConfig(
            key = "ting85",
            name = "Ting85",
            base = "https://www.85ting.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.85ting.com/list/851.html", "武侠" to "https://www.85ting.com/list/852.html",
                "悬疑" to "https://www.85ting.com/list/853.html", "历史" to "https://www.85ting.com/list/854.html",
                "军事" to "https://www.85ting.com/list/855.html", "评书" to "https://www.85ting.com/list/856.html",
            ),
        ),
        SiteConfig(
            key = "ting954",
            name = "Ting954",
            base = "https://www.ting954.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.ting954.com/list/9541.html", "武侠" to "https://www.ting954.com/list/9542.html",
                "悬疑" to "https://www.ting954.com/list/9543.html", "历史" to "https://www.ting954.com/list/9544.html",
                "军事" to "https://www.ting954.com/list/9545.html", "评书" to "https://www.ting954.com/list/9546.html",
            ),
        ),
        SiteConfig(
            key = "tingdada",
            name = "TingDaDa",
            base = "https://www.tingdada.com",
            bookHrefPattern = "/books/(\\d+)\\.html",
            cats = listOf(
                "玄幻" to "https://www.tingdada.com/html/551.html", "言情" to "https://www.tingdada.com/html/552.html",
                "都市" to "https://www.tingdada.com/html/553.html", "恐怖" to "https://www.tingdada.com/html/554.html",
                "惊悚" to "https://www.tingdada.com/html/555.html", "推理" to "https://www.tingdada.com/html/556.html",
            ),
            chapterPattern = "/mp3/(\\d+)-(\\d+)-(\\d+)\\.html",
            chapterPrefix = "/mp3/",
        ),
        SiteConfig(
            key = "tingshuw",
            name = "TingShuW",
            base = "https://www.tingshuw.com",
            bookHrefPattern = "/mp3/(\\d+)\\.html",
            cats = listOf(
                "玄幻" to "https://www.tingshuw.com/book/1.html", "言情" to "https://www.tingshuw.com/book/2.html",
                "都市" to "https://www.tingshuw.com/book/3.html", "恐怖" to "https://www.tingshuw.com/book/4.html",
                "惊悚" to "https://www.tingshuw.com/book/5.html", "推理" to "https://www.tingshuw.com/book/6.html",
            ),
        ),
        SiteConfig(
            key = "tingworld",
            name = "TingWorld",
            base = "http://www.tingworld.com",
            bookHrefPattern = "/ting/(\\d+)\\.html",
            cats = listOf(
                "言情" to "http://www.tingworld.com/world/2111.html", "武侠" to "http://www.tingworld.com/world/2112.html",
                "悬疑" to "http://www.tingworld.com/world/2113.html", "历史" to "http://www.tingworld.com/world/2114.html",
                "军事" to "http://www.tingworld.com/world/2115.html", "评书" to "http://www.tingworld.com/world/2116.html",
            ),
        ),
        SiteConfig(
            key = "yitingshu",
            name = "YiTingShu",
            base = "https://www.yitingshu.com",
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.yitingshu.com/yi/1.html", "武侠" to "https://www.yitingshu.com/yi/2.html",
                "悬疑" to "https://www.yitingshu.com/yi/3.html", "历史" to "https://www.yitingshu.com/yi/4.html",
                "军事" to "https://www.yitingshu.com/yi/5.html", "评书" to "https://www.yitingshu.com/yi/6.html",
            ),
        ),
        SiteConfig(
            key = "aj006",
            name = "Aj006",
            base = "http://aj006.com",
            bookHrefPattern = "/mp3/(\\d+)\\.html",
            cats = listOf(
                "首页" to "http://aj006.com/list/661.html",
            ),
        ),
        SiteConfig(
            key = "jiongzei",
            name = "Jiongzei",
            base = "https://jiongzei.com",
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf("首页" to "https://jiongzei.com/"),
        ),
        SiteConfig(
            key = "leting8",
            name = "Leting8",
            base = "https://www.leting8.com",
            bookHrefPattern = "/so/(\\d+)\\.html",
            cats = listOf("首页" to "https://www.leting8.com/"),
        ),
        SiteConfig(
            key = "yuetingba",
            name = "Yuetingba",
            // 实测 2026-11-23：https 入口 301 到 http（不是 https），Ktor 不跟跨协议跳转
            // → 拿到的是 147 字节“对象已移动”页，0 本书。base 直接用 http。
            base = "http://www.yuetingba.cn",
            // 书籍链接是 /book/detail/<uuid>/0（旧配置写死 /1，一个都匹配不上）
            bookHrefPattern = "/book/detail/([A-Za-z0-9-]+)/0",
            // 章节在 /book/ting/<uuid>，一页 40 集；第 N 页 = /book/detail/<uuid>/<N*40>
            chapterPattern = "/book/ting/([A-Za-z0-9-]+)",
            chapterPathGroup = -1,
            chapterMode = TemplateTingSite.ChapterMode.HtmlPages,
            htmlPagePattern = "{url}/{page}",
            // P1-3：实测这本书 931 集，分页是 /0、/200、/400、/600、/800。
            // 每页 200 集，不是 40。之前配 40 会请求不存在的页（302 回第 0 页），
            // 导致永远只抓到第一页的 200 集。
            htmlPageStart = 200,
            htmlPageStep = 200,
            htmlMaxPages = 10,   // 2000 集封顶，够用了
            // 播放器也是 JS：GET /api/app/docs-listen/<tingId>/audio-url 响应正文就是 mp3 直链
            audioApiUrlPattern = "/api/app/docs-listen/{id}/audio-url",
            cats = listOf("首页" to "http://www.yuetingba.cn/"),
        ),
        SiteConfig(
            key = "ting15",
            name = "Ting15",
            // 实测 2026-11-23：m.ting15.com 是精简版，分类页 /wuxiaxuanhuan/ 和 /wuxiaxuanhuan/1.html 都没有书籍链接；
            // www.ting15.com 才是完整站。书页 = /分类/N.html，章节 = /分类/N/卷-集.html（按分类分目录，不是全局 /N.html）
            base = "https://www.ting15.com",
            bookHrefPattern = "/(?:wuxiaxuanhuan|dushiyanqing|kongbulingyi|tuilixuanyi|jiatinglunli|wenxuemingzhu|jingdianpingshu|quyixiqu|xiangshengxiaopin|yinyue)/(\\d+)\\.html",
            cats = listOf(
                "武侠玄幻" to "https://www.ting15.com/wuxiaxuanhuan/", "都市言情" to "https://www.ting15.com/dushiyanqing/", "恐怖灵异" to "https://www.ting15.com/kongbulingyi/", "推理悬疑" to "https://www.ting15.com/tuilixuanyi/", "经典评书" to "https://www.ting15.com/jingdianpingshu/", "官场职场" to "https://www.ting15.com/wenxuemingzhu/"
            ),
            // 章节在分类子目录里：/wuxiaxuanhuan/1254/0-1.html（两段，不是 N-N-N）。
            // 用 chapterPathGroup = -1 表示“整段匹配就是章节 URL”，不拼接。
            chapterPattern = "/(?:wuxiaxuanhuan|dushiyanqing|kongbulingyi|tuilixuanyi|jiatinglunli|wenxuemingzhu|jingdianpingshu|quyixiqu|xiangshengxiaopin|yinyue)/\\d+/\\d+-\\d+\\.html",
            chapterPrefix = "",
            chapterPathGroup = -1,
            // 播放器是 JS：POST /?s=api-getneoplay {bookId,isPay,page}，响应 {"url":"...m4a","status":1}
            // 从播放页的 <meta _b/_cp/_p/_c/_l> 取参数与验证头
            audioApiPattern = "/?s=api-getneoplay",
        ),
        SiteConfig(
            key = "vbus",
            name = "VBUS",
            base = "https://www.vbus.cc",
            // 实测 2026-11-23：
            //  - /v/N 是"节目不存在"占位页（旧 books//(\d+) 抓的就是它，所以 6.7KB 无章节）
            //  - /api/v1/program/list 存在，但 album_id/album/aid 参数全被忽略，恒返回全站最新 6852 条
            //    （试过 album_id/album/albumId/aid 四种，total 都是 6852）——不能用
            //  - 真数据在专辑页 HTML：/album/1064 每页 20 条 <a href="/v/5893">，第 N 页 /album/1064/N
            //  - 节目音频：/program/get-source/5893 是 302 → files.vbus.cc/xxx.mp3（带过期签名），
            //    直接把 302 口交给播放器，比在这里取一次签名更耐放
            bookHrefPattern = "/album/(\\d+)",
            cats = listOf(
                "最新" to "https://www.vbus.cc/album/new",
                "最热" to "https://www.vbus.cc/album/hot",
                "推荐" to "https://www.vbus.cc/album/recommend",
            ),
            chapterMode = TemplateTingSite.ChapterMode.HtmlPages,
            htmlPagePattern = "{url}/{page}",
            htmlMaxPages = 40,
        ),
        SiteConfig(
            key = "ytysxs",
            name = "Ytysxs",
            base = "https://www.ytysxs.com",
            // 实测 2026-11-23：WordPress + audioigniter 播放器，没有 /play/N-N-N.html。
            // 书页里每个 <div data-tracks-url="?audioigniter_playlist_id=N"> 是一个 100 集的分块，
            // 拉该 URL 返回 JSON 数组 [{title,audio,cover}]，audio 就是 mp3.ytysxs.top 上的直链。
            bookHrefPattern = "/(\\d+)\\.html",
            cats = listOf(
                "言情" to "https://www.ytysxs.com/yanqing/", "玄幻" to "https://www.ytysxs.com/xuanhuan/",
                "都市" to "https://www.ytysxs.com/dushi/", "历史" to "https://www.ytysxs.com/lishi/",
                "科幻" to "https://www.ytysxs.com/kehuan/", "仙侠" to "https://www.ytysxs.com/xianxia/",
            ),
            chapterMode = TemplateTingSite.ChapterMode.Playlist,
        ),
    )

    fun build(fetcher: JsonFetcher, throttle: RequestThrottle): List<TemplateTingSite> =
        all.map { it.toSite(fetcher, throttle) }

    fun byKey(key: String, fetcher: JsonFetcher, throttle: RequestThrottle): TemplateTingSite? =
        all.firstOrNull { it.key == key }?.toSite(fetcher, throttle)

    /**
     * 唯一装配点：SourceRegistry 和 byKey 都走这里。
     * P0（审计）：之前 SourceRegistry 自己 inline 装配，漏传 chapterPattern/chapterPrefix，
     * 结果是 tingdada 在 App 里拿 0 章，只有 CLI 的 byKey 路径正常。
     */
    private fun SiteConfig.toSite(fetcher: JsonFetcher, throttle: RequestThrottle) = TemplateTingSite(
        fetcher = fetcher, throttle = throttle,
        base = base, siteName = name,
        cats = cats, bookHrefPattern = bookHrefPattern,
        chapterPattern = chapterPattern,
        chapterPrefix = chapterPrefix,
        chapterMode = chapterMode,
        jsonApiPattern = jsonApiPattern,
        jsonListKey = jsonListKey,
        jsonUrlKey = jsonUrlKey,
        jsonAudioKey = jsonAudioKey,
        jsonTitleKey = jsonTitleKey,
        jsonCoverKey = jsonCoverKey,
        htmlPagePattern = htmlPagePattern,
        htmlMaxPages = htmlMaxPages,
        htmlPageStart = htmlPageStart,
        htmlPageStep = htmlPageStep,
        chapterPathGroup = chapterPathGroup,
        audioApiPattern = audioApiPattern,
        audioApiUrlPattern = audioApiUrlPattern,
        sourceId = key,
    )
}
