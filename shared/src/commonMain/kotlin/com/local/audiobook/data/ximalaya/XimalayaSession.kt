package com.local.audiobook.data.ximalaya

/**
 * 喜马拉雅登录态的纯规则（可单测，不碰平台）。
 *
 * 判定逻辑沿用服务器桥里已验证的那套：
 *  - 出现 `1&_token` → 已登录（主判据）
 *  - 或 `xmly` + `1&_device` 同时存在 → 已登录（部分登录路径不写 1&_token）
 *
 * 迁移记录（T03 §19.7，2026-11-21）：自 audiobook-app data/ximalaya 原样搬入 commonMain，
 * 包名不变（安卓零 import 改动）；零平台 API，无逻辑改动。
 */
object XimalayaSessionRules {

    /** 主判据 cookie 名 */
    const val KEY_TOKEN = "1&_token"

    /** 辅助判据 */
    const val KEY_XMLY = "xmly"
    const val KEY_DEVICE = "1&_device"

    /** 需要覆盖的域名（www 与 m 两个子域都要导出） */
    val COOKIE_URLS: List<String> = listOf(
        "https://www.ximalaya.com",
        "https://m.ximalaya.com",
        "https://passport.ximalaya.com",
    )

    /** 把 "k1=v1; k2=v2" 解析成 Map。纯函数。空值、无等号的片段直接丢弃。 */
    fun parseCookieString(raw: String?): Map<String, String> {
        if (raw.isNullOrBlank()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        raw.split(";").forEach { part ->
            val p = part.trim()
            if (p.isEmpty()) return@forEach
            val idx = p.indexOf('=')
            if (idx <= 0) return@forEach
            val k = p.substring(0, idx).trim()
            val v = p.substring(idx + 1).trim()
            if (k.isNotEmpty() && v.isNotEmpty()) out[k] = v
        }
        return out
    }

    /** 登录态判定（纯函数） */
    fun isLoggedIn(cookies: Map<String, String>): Boolean {
        if (cookies.containsKey(KEY_TOKEN)) return true
        return cookies.containsKey(KEY_XMLY) && cookies.containsKey(KEY_DEVICE)
    }

    /** 只保留"对我们有用"的 cookie（纯函数），减少泄露面。 */
    fun filterForStorage(cookies: Map<String, String>): Map<String, String> {
        val keep = listOf(
            KEY_TOKEN, KEY_XMLY, KEY_DEVICE, "1&_remember", "1&_token_expire",
            "ximalaya", "channel", "impl", "1&_ln", "1&_m",
        )
        return cookies.filterKeys { k -> keep.contains(k) }
    }

    /** Map 还原成 Cookie 头（键排序，同一组 cookie 输出稳定）。 */
    fun toCookieHeader(cookies: Map<String, String>): String =
        cookies.entries.sortedBy { it.key }.joinToString("; ") { "${it.key}=${it.value}" }

    /** 判定一次响应是否代表"登录已失效" */
    fun isAuthExpired(retCode: Int?, isNeedLogin: Boolean?): Boolean =
        isNeedLogin == true || retCode == 401 || retCode == 402
}
