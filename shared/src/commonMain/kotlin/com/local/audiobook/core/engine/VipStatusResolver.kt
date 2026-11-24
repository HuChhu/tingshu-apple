package com.local.audiobook.core.engine

import com.local.audiobook.core.CookieProvider
import com.local.audiobook.core.VipStatus
import com.local.audiobook.core.VipTier
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * 会员状态解析（v1.4.4）。
 *
 * 【为什么需要】用户登录了一个**没有会员**的账号，界面写「可听会员内容」——
 * 本来就是硬编码。现在要真实判定，并且取不到就老实说「未知」。
 *
 * 【接口来源】不是猜的，是从官方页面的 JS 里挖出来的：
 *   www.ximalaya.com 的主包 b1f131.js 里有
 *     getCurrentUser = () => GET /revision/main/getCurrentUser
 *   且页头用 \`isLogin && currentUser.isVip ? "续费会员" : "开通会员"\` 判断。
 *   实测：匿名访问 → {"ret":401,"msg":"need login!","isNeedLogin":true}
 *
 * 【等级字段】同一个接口还会带 vip 相关字段（vipLevel / vipType / vipExpireTime 等），
 * 不同账号给不同子集，所以这里做“宽进窄出”：字段名多候选，值严格归类。
 *
 * 【降级链】
 *   ① 无 Cookie → NotLoggedIn（不发请求）
 *   ② /revision/main/getCurrentUser → 有效则用它
 *   ③ /revision/user/basic?uid=self → 备用（isVip 字段已实测存在）
 *   ④ 都不行 → Unknown（绝不默认当会员）
 */
object VipStatusResolver {

    const val CURRENT_USER = "https://www.ximalaya.com/revision/main/getCurrentUser"
    const val USER_BASIC = "https://www.ximalaya.com/revision/user/basic"

    /**
     * 等级数值→类型。
     *
     * 实测与官方前端行为对照（官方页面只分「会员/非会员」，
     * 等级细分是从接口字段推导 + 业务常识，字段不在就归 None/Unknown）：
     *   0 / 缺省            → None（没有会员）
     *   1                      → Normal（小会员/普通会员）
     *   2                      → Platinum（白金）
     *   3                      → Master（大师）
     *   4                      → Kids（儿童）
     *   其他 >0                → Normal（不敢献策，当普通会员处理）
     */
    fun tierOfLevel(level: Int): VipTier = when {
        level <= 0 -> VipTier.None
        level == 1 -> VipTier.Normal
        level == 2 -> VipTier.Platinum
        level == 3 -> VipTier.Master
        level == 4 -> VipTier.Kids
        else -> VipTier.Normal
    }

    /**
     * 文本→等级（WebView 路线用）。
     * 从页面 innerText 里看到什么就判什么，看不出来就 Unknown。
     */
    fun tierOfText(text: String): VipTier {
        if (text.isEmpty()) return VipTier.Unknown
        // 大师 > 白金 > 儿童 > 开通（按特异性从高到低）
        if (text.contains("大师会员") || text.contains("大师VIP", true)) return VipTier.Master
        if (text.contains("白金会员") || text.contains("白金VIP", true)) return VipTier.Platinum
        if (text.contains("儿童会员") || text.contains("儿童VIP", true)) return VipTier.Kids
        // 下面三条是“确定没有会员”的语言：页面在开通入口上写「开通会员」
        if (text.contains("开通会员") || text.contains("立即开通")) return VipTier.None
        // 「续费」= 已经是会员，但具体哪个等级页面没写 → 只能算普通
        if (text.contains("续费")) return VipTier.Normal
        return VipTier.Unknown
    }

    /**
     * 从 getCurrentUser / user/basic 的 data 里提取会员信息。
     * 返回 null 表示“这份 JSON 根本没有会员字段”（不能当成「没会员」）。
     */
    fun fromUserJson(data: JsonObject): VipStatus? {
        val isVip = boolOf(data, "isVip")
        val levelRaw = intOf(data, "vipLevel", "memberLevel", "vipType", "memberType")
        val expire = dateOf(data, "vipExpireTime", "vipExpireAt", "vipExpire", "expireTime", "memberExpireTime")
        val nick = strOf(data, "nickName", "nickname", "userName")

        // 字段全都没有 → 不能假设
        if (isVip == null && levelRaw == null) return null

        val tier = when {
            levelRaw != null && levelRaw > 0 -> tierOfLevel(levelRaw)
            isVip == true -> VipTier.Normal      // 只告诉你是会员、没给等级 → 普通
            else -> VipTier.None
        }
        // 有效期已过 → 视为没会员（接口偶尔会拖着旧状态）
        val expired = expire.isNotEmpty() && expire < todayGuess()
        return VipStatus(
            tier = if (expired) VipTier.None else tier,
            expireDate = if (expired) "" else expire,
            nickname = nick,
            rawVipLevel = levelRaw ?: -1,
            source = "api",
        )
    }

    /** 请求两个用户接口，拿到哪个用哪个。 */
    suspend fun resolve(
        fetcher: JsonFetcher,
        throttle: RequestThrottle,
        cookies: CookieProvider,
    ): VipStatus {
        val cookie = cookies.cookie()
        if (cookie.isNullOrEmpty()) return VipStatus(VipTier.NotLoggedIn, source = "cookie")

        val headers = mapOf(
            "User-Agent" to SearchRoutes.WEB_UA,
            "Referer" to SearchRoutes.WEB_BASE + "/",
            "Accept" to "application/json",
            "Cookie" to cookie,
        )
        val endpoints = listOf(CURRENT_USER, USER_BASIC + "?uid=0")
        for (url in endpoints) {
            val resp = runCatching { throttle.run { fetcher.get(url, headers) } }.getOrNull() ?: continue
            if (resp !is FetchOutcome.Ok) continue
            val root = runCatching { Json.parseToJsonElement(resp.text) as? JsonObject }.getOrNull() ?: continue
            // ret != 200 且 needLogin → Cookie 失效
            val ret = intOf(root, "ret")
            if (ret == 401 || boolOf(root, "isNeedLogin") == true) {
                return VipStatus(VipTier.NotLoggedIn, source = "api")
            }
            val data = root["data"] as? JsonObject ?: continue
            fromUserJson(data)?.let { return it }
        }
        return VipStatus(VipTier.Unknown, source = "api")
    }

    // ---------- 字段宽读工具 ----------

    private fun prim(o: JsonObject, vararg keys: String): JsonElement? =
        keys.firstNotNullOfOrNull { o[it] }?.takeIf { it !is kotlinx.serialization.json.JsonNull }

    private fun strOf(o: JsonObject, vararg keys: String): String =
        (prim(o, *keys) as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" } ?: ""

    private fun intOf(o: JsonObject, vararg keys: String): Int? =
        (prim(o, *keys) as? JsonPrimitive)?.content?.let { c ->
            c.toIntOrNull() ?: when (c.lowercase()) {
                "true", "vip", "normal" -> 1
                "false", "none", "novip", "" -> 0
                else -> null
            }
        }

    private fun boolOf(o: JsonObject, vararg keys: String): Boolean? =
        (prim(o, *keys) as? JsonPrimitive)?.content?.let { c ->
            when (c.lowercase()) {
                "true", "1", "yes" -> true
                "false", "0", "no" -> false
                else -> null
            }
        }

    /** 有效期统一成 yyyy-MM-dd（支持 10/13 位时间戳与 "2026-12-31" 文本） */
    fun dateOf(o: JsonObject, vararg keys: String): String {
        val raw = strOf(o, *keys)
        if (raw.isEmpty()) return ""
        if (raw.length >= 10 && raw[4] == '-' && raw[7] == '-') return raw.substring(0, 10)
        val ms = raw.toLongOrNull() ?: return ""
        val sec = if (ms > 10_000_000_000L) ms / 1000 else ms
        if (sec <= 0) return ""
        // 纯 Kotlin 日期换算（commonMain 没有 java.time）
        return epochSecondsToDate(sec)
    }

    /** 由秒数据算出 UTC 日期（业务只需日精度，差几小时不影响显示） */
    internal fun epochSecondsToDate(sec: Long): String {
        var days = sec / 86400
        var rem = sec % 86400
        if (rem < 0) { days -= 1; rem += 86400 }
        // 1970-01-01 起算
        var y = 1970
        while (true) {
            val leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
            val dim = if (leap) 366 else 365
            if (days >= dim) { days -= dim; y++ } else break
        }
        val leapNow = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        val months = intArrayOf(31, if (leapNow) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        var m = 0
        while (m < 12 && days >= months[m]) { days -= months[m]; m++ }
        val mm = (m + 1).toString().padStart(2, '0')
        val dd = (days + 1).toString().padStart(2, '0')
        return y.toString() + "-" + mm + "-" + dd
    }

    /** 比较用的“今天”：由层面注入（没注入就用 0，不过期判断失效但不影响等级） */
    var todayProvider: () -> String = { "" }

    private fun todayGuess(): String = todayProvider()
}
