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
            bookHrefPattern = "/tingshu/(\\d+)\\.html",
            cats = listOf(
                "首页" to "https://www.gushiya.com/",
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
            base = "https://www.yuetingba.cn",
            bookHrefPattern = "/book/detail/([A-Za-z0-9-]+)/1",
            cats = listOf("首页" to "https://www.yuetingba.cn/"),
        ),
        SiteConfig(
            key = "ting15",
            name = "Ting15",
            base = "https://m.ting15.com",
            bookHrefPattern = "/(\\d+)\\.html",
            cats = listOf("武侠玄幻" to "https://m.ting15.com/wuxiaxuanhuan/1.html", "都市言情" to "https://m.ting15.com/dushiyanqing/1.html"),
        ),
        SiteConfig(
            key = "vbus",
            name = "VBUS",
            base = "https://www.vbus.cc",
            bookHrefPattern = "/album/(\\d+)",
            cats = listOf("首页" to "https://www.vbus.cc/"),
        ),
        SiteConfig(
            key = "ytysxs",
            name = "Ytysxs",
            base = "https://www.ytysxs.com",
            bookHrefPattern = "/(\\d+)\\.html",
            cats = listOf("首页" to "https://www.ytysxs.com/"),
        ),
    )

    fun build(fetcher: JsonFetcher, throttle: RequestThrottle): List<TemplateTingSite> =
        all.map { c ->
            TemplateTingSite(
                fetcher = fetcher, throttle = throttle,
                base = c.base, siteName = c.name,
                cats = c.cats, bookHrefPattern = c.bookHrefPattern,
                sourceId = c.key,
            )
        }

    fun byKey(key: String, fetcher: JsonFetcher, throttle: RequestThrottle): TemplateTingSite? {
        val c = all.firstOrNull { it.key == key } ?: return null
        return TemplateTingSite(
            fetcher = fetcher, throttle = throttle,
            base = c.base, siteName = c.name,
            cats = c.cats, bookHrefPattern = c.bookHrefPattern,
            sourceId = c.key,
        )
    }
}
