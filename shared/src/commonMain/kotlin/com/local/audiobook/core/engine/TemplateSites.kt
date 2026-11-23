package com.local.audiobook.core.engine

import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle

/**
 * 模板站配置表（Template Site Registry）
 *
 * 【来源】从 14 个 jar 的 XmTingSite 子类构造函数逐字节提取。
 * 每个站只需要 base + 分类 URL 列表，解析逻辑由 TemplateTingSite 统一处理。
 *
 * 【实测 2026-11-23】28 个站中 26 个存活：
 *   死了：ErDuoWang(000) / Ting05(000)
 *   跳转：Ting92(301)
 *
 * 【意义】26 个站 = 1 个引擎 + 26 条配置，不需要逐个写解析器。
 */
object TemplateSites {

    /** 配置项：站名 + 根地址 + 分类 */
    data class SiteConfig(
        val key: String,
        val name: String,
        val base: String,
        val cats: List<Pair<String, String>>,
    )

    /** 全部存活站点（按站名字母序） */
    val all: List<SiteConfig> = listOf(
        SiteConfig(
            key = "ainaicha",
            name = "AiNaiCha",
            base = "https://www.ainaicha.com",
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
            cats = listOf(
                "言情" to "https://www.aisongli.com/ai/1.html", "武侠" to "https://www.aisongli.com/ai/2.html",
                "悬疑" to "https://www.aisongli.com/ai/3.html", "历史" to "https://www.aisongli.com/ai/4.html",
                "军事" to "https://www.aisongli.com/ai/5.html", "评书" to "https://www.aisongli.com/ai/6.html",
            ),
        ),
        SiteConfig(
            key = "dengdeng",
            name = "DengDeng",
            base = "https://www.deng-deng.com",
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
            cats = listOf(
                "言情" to "https://www.ebiaoyan.com/list/1531.html", "武侠" to "https://www.ebiaoyan.com/list/1532.html",
                "悬疑" to "https://www.ebiaoyan.com/list/1533.html", "历史" to "https://www.ebiaoyan.com/list/1534.html",
                "军事" to "https://www.ebiaoyan.com/list/1535.html", "评书" to "https://www.ebiaoyan.com/list/1536.html",
            ),
        ),
        SiteConfig(
            key = "eshengda",
            name = "EShengDa",
            base = "https://www.eshengda.com",
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
            cats = listOf(
                "言情" to "https://www.gushiya.com/ya/1581.html", "武侠" to "https://www.gushiya.com/ya/1582.html",
                "悬疑" to "https://www.gushiya.com/ya/1583.html", "历史" to "https://www.gushiya.com/ya/1584.html",
                "军事" to "https://www.gushiya.com/ya/1585.html", "评书" to "https://www.gushiya.com/ya/1586.html",
            ),
        ),
        SiteConfig(
            key = "hongmujie",
            name = "HongMuJie",
            base = "https://www.hongmujie.com",
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
            cats = listOf(
                "言情" to "https://www.ihonghai.com/i/1.html", "武侠" to "https://www.ihonghai.com/i/2.html",
                "悬疑" to "https://www.ihonghai.com/i/3.html", "历史" to "https://www.ihonghai.com/i/4.html",
                "军事" to "https://www.ihonghai.com/i/5.html", "评书" to "https://www.ihonghai.com/i/6.html",
            ),
        ),
        SiteConfig(
            key = "ilehao",
            name = "ILeHao",
            base = "https://www.ilehao.com",
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
            cats = listOf(
                "言情" to "https://picfxapp.com/app/6901.html", "武侠" to "https://picfxapp.com/app/6902.html",
                "悬疑" to "https://picfxapp.com/app/6903.html", "历史" to "https://picfxapp.com/app/6904.html",
                "军事" to "https://picfxapp.com/app/6905.html", "评书" to "https://picfxapp.com/app/6906.html",
            ),
        ),
        SiteConfig(
            key = "qmtsw",
            name = "Qmtsw",
            base = "https://www.qmtsw.com",
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
            cats = listOf(
                "言情" to "https://www.yitingshu.com/yi/1.html", "武侠" to "https://www.yitingshu.com/yi/2.html",
                "悬疑" to "https://www.yitingshu.com/yi/3.html", "历史" to "https://www.yitingshu.com/yi/4.html",
                "军事" to "https://www.yitingshu.com/yi/5.html", "评书" to "https://www.yitingshu.com/yi/6.html",
            ),
        ),
    )

    /** 按 key 建实例 */
    fun build(
        fetcher: JsonFetcher,
        throttle: RequestThrottle,
    ): List<TemplateTingSite> = all.map { c ->
        TemplateTingSite(
            fetcher = fetcher,
            throttle = throttle,
            base = c.base,
            siteName = c.name,
            cats = c.cats,
            sourceId = c.key,
        )
    }

    /** 站名 → 实例 */
    fun byKey(
        key: String,
        fetcher: JsonFetcher,
        throttle: RequestThrottle,
    ): TemplateTingSite? {
        val c = all.firstOrNull { it.key == key } ?: return null
        return TemplateTingSite(
            fetcher = fetcher,
            throttle = throttle,
            base = c.base,
            siteName = c.name,
            cats = c.cats,
            sourceId = c.key,
        )
    }
}
