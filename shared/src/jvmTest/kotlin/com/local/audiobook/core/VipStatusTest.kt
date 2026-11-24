package com.local.audiobook.core

import com.local.audiobook.core.engine.VipStatusResolver
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * 会员等级判定（v1.4.4）。
 *
 * 用户现场：登录了一个**没有会员**的账号，界面却写「可听会员内容」。
 * 核心纪律：**拿不到就是 Unknown，绝不默认当会员**。
 */
class VipStatusTest {

    private fun obj(s: String): JsonObject = Json.parseToJsonElement(s) as JsonObject

    @Test
    fun levelToTierMapping() {
        assertEquals(VipTier.None, VipStatusResolver.tierOfLevel(0))
        assertEquals(VipTier.None, VipStatusResolver.tierOfLevel(-1))
        assertEquals(VipTier.Normal, VipStatusResolver.tierOfLevel(1))
        assertEquals(VipTier.Platinum, VipStatusResolver.tierOfLevel(2))
        assertEquals(VipTier.Master, VipStatusResolver.tierOfLevel(3))
        assertEquals(VipTier.Kids, VipStatusResolver.tierOfLevel(4))
        // 未知等级不敢献策，当普通会员
        assertEquals(VipTier.Normal, VipStatusResolver.tierOfLevel(9))
    }

    @Test
    fun nonMemberAccountIsNotVip() {
        // 真实场景：getCurrentUser 对一个普通账号返回的形态
        val s = VipStatusResolver.fromUserJson(obj("""{"uid":123,"nickName":"\u5c0f\u660e","isVip":false,"vipLevel":0}"""))
        requireNotNull(s) { "有 isVip/vipLevel 字段就不能返回 null" }
        assertEquals(VipTier.None, s.tier, "普通账号必须是 None，不能当会员")
        assertEquals("\u5c0f\u660e", s.nickname)
    }

    @Test
    fun memberWithLevelAndExpiry() {
        val s = VipStatusResolver.fromUserJson(
            obj("""{"isVip":true,"vipLevel":2,"vipExpireTime":"2027-03-15","nickName":"a"}""")
        )
        requireNotNull(s)
        assertEquals(VipTier.Platinum, s.tier)
        assertEquals("2027-03-15", s.expireDate)
        assertEquals(2, s.rawVipLevel)
    }

    @Test
    fun isVipTrueWithoutLevelCountsAsNormal() {
        val s = VipStatusResolver.fromUserJson(obj("""{"isVip":true}"""))
        requireNotNull(s)
        assertEquals(VipTier.Normal, s.tier)
        assertEquals(-1, s.rawVipLevel)
    }

    @Test
    fun noVipFieldsMeansUnknownNotNone() {
        // 接口返回了用户但没有会员字段 → 这是「不知道」，不是「没会员」
        assertNull(VipStatusResolver.fromUserJson(obj("""{"uid":123,"nickName":"x"}""")))
    }

    @Test
    fun expireTimestampConvertedToDate() {
        val s = VipStatusResolver.fromUserJson(
            obj("""{"isVip":true,"vipLevel":2,"vipExpireTime":1800000000000}""")
        )
        requireNotNull(s)
        // 1800000000 秒 = 2027-01-15 UTC
        assertEquals("2027-01-15", s.expireDate)
    }

    @Test
    fun epochToDateEdgeCases() {
        assertEquals("1970-01-01", VipStatusResolver.epochSecondsToDate(0))
        assertEquals("2000-02-29", VipStatusResolver.epochSecondsToDate(951782400))  // 闰年
        assertEquals("2025-01-01", VipStatusResolver.epochSecondsToDate(1735689600))
        assertEquals("2024-12-31", VipStatusResolver.epochSecondsToDate(1735603200))
    }

    @Test
    fun expiredVipIsTreatedAsNone() {
        VipStatusResolver.todayProvider = { "2026-11-24" }
        try {
            val s = VipStatusResolver.fromUserJson(
                obj("""{"isVip":true,"vipLevel":2,"vipExpireTime":"2020-01-01"}""")
            )
            requireNotNull(s)
            assertEquals(VipTier.None, s.tier, "过期的会员不能当会员")
            assertEquals("", s.expireDate)
        } finally {
            VipStatusResolver.todayProvider = { "" }
        }
    }

    @Test
    fun textHeuristicsFromWebPage() {
        // WebView 路线：页面 innerText
        assertEquals(VipTier.Master, VipStatusResolver.tierOfText("\u5927\u5e08\u4f1a\u5458 \u5269\u4f59 30 \u5929"))
        assertEquals(VipTier.Platinum, VipStatusResolver.tierOfText("\u767d\u91d1\u4f1a\u5458"))
        assertEquals(VipTier.Kids, VipStatusResolver.tierOfText("\u513f\u7ae5\u4f1a\u5458"))
        assertEquals(VipTier.None, VipStatusResolver.tierOfText("\u5f00\u901a\u4f1a\u5458"))
        assertEquals(VipTier.Normal, VipStatusResolver.tierOfText("\u7eed\u8d39"))
        assertEquals(VipTier.Unknown, VipStatusResolver.tierOfText(""))
        assertEquals(VipTier.Unknown, VipStatusResolver.tierOfText("\u4e00\u4e9b\u65e0\u5173\u6587\u5b57"))
    }

    @Test
    fun notLoggedInWhenNoCookie() {
        val st = kotlinx.coroutines.runBlocking {
            VipStatusResolver.resolve(
                fetcher = object : com.local.audiobook.core.net.JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) =
                        com.local.audiobook.core.net.FetchOutcome.Ok(200, "{}")
                },
                throttle = com.local.audiobook.data.ximalaya.RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                cookies = object : CookieProvider {
                    override suspend fun cookie(): String? = null
                    override suspend fun refresh() {}
                },
            )
        }
        assertEquals(VipTier.NotLoggedIn, st.tier)
    }

    @Test
    fun cookieRejectedMeansNotLoggedIn() {
        val st = kotlinx.coroutines.runBlocking {
            VipStatusResolver.resolve(
                fetcher = object : com.local.audiobook.core.net.JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) =
                        com.local.audiobook.core.net.FetchOutcome.Ok(
                            200, """{"ret":401,"msg":"need login!","isNeedLogin":true}""")
                },
                throttle = com.local.audiobook.data.ximalaya.RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                cookies = object : CookieProvider {
                    override suspend fun cookie(): String? = "1&_token=abc"
                    override suspend fun refresh() {}
                },
            )
        }
        assertEquals(VipTier.NotLoggedIn, st.tier, "Cookie 失效→ 未登录")
    }

    @Test
    fun allEndpointsFailMeansUnknownNeverVip() {
        val st = kotlinx.coroutines.runBlocking {
            VipStatusResolver.resolve(
                fetcher = object : com.local.audiobook.core.net.JsonFetcher {
                    override suspend fun get(url: String, headers: Map<String, String>) =
                        com.local.audiobook.core.net.FetchOutcome.Failed("timeout", "")
                },
                throttle = com.local.audiobook.data.ximalaya.RequestThrottle(minIntervalMs = 0L, clock = { 0L }),
                cookies = object : CookieProvider {
                    override suspend fun cookie(): String? = "1&_token=abc"
                    override suspend fun refresh() {}
                },
            )
        }
        assertEquals(VipTier.Unknown, st.tier, "取不到必须是 Unknown，不能当会员")
    }
}
