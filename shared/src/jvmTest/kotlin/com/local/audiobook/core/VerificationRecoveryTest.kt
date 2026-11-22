package com.local.audiobook.core

import com.local.audiobook.core.engine.VerificationRecovery
import com.local.audiobook.core.engine.VerificationRecovery.VerificationType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 验证恢复单测。
 * 用例全部来自喜马拉雅的真实响应（本次会话实测），不是编的。
 */
class VerificationRecoveryTest {

    private fun cls(status: Int, body: String) = VerificationRecovery.classify(status, body)

    // ---------- 真实响应：搜索风控 ----------

    @Test
    fun realRiskInvalidIsVerification() {
        val body = """{"ret":200,"data":{"reason":"risk invalid","illegal":false,"kw":"三体","riskLevel":5}}"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification, "应识别为需验证")
        assertEquals(VerificationType.Login, (f as VerificationRecovery.Failure.NeedsVerification).type)
        assertTrue(f.detail.contains("风控"))
    }

    @Test
    fun riskLevelLowIsNotVerification() {
        // riskLevel 1/2 不算强拦截
        val body = """{"ret":200,"data":{"riskLevel":1}}"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.Ordinary)
    }

    // ---------- 真实响应：webtk 缺失 ----------

    @Test
    fun realWebtkMissingIsVerification() {
        val body = """{"ret":407,"msg":"webtk缺失","code":5,"isNeedLogin":false}"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification)
        assertTrue((f as VerificationRecovery.Failure.NeedsVerification).detail.contains("webtk"))
    }

    // ---------- 真实响应：登录墙 ----------

    @Test
    fun realLoginRequiredIsVerification() {
        val body = """{"apiStatus":485,"data":{},"msg":"你好，需要登录才能继续使用此功能","status":485}"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification)
    }

    @Test
    fun realRet401IsVerification() {
        val f = cls(200, """{"ret":401,"isNeedLogin":true}""")
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification)
    }

    // ---------- 真实响应：极验 ----------

    @Test
    fun realGeetestSliderIsVerification() {
        val body = """<div class="geetest_panel">Slide to complete the puzzle</div>"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification)
        assertEquals(VerificationType.Slider, (f as VerificationRecovery.Failure.NeedsVerification).type)
    }

    @Test
    fun realGeetestClickSelectDetected() {
        val body = """<div class="geetest_box">Select in this order OK Close</div>"""
        val f = cls(200, body)
        assertTrue(f is VerificationRecovery.Failure.NeedsVerification)
        assertEquals(VerificationType.ClickSelect, (f as VerificationRecovery.Failure.NeedsVerification).type)
    }

    // ---------- 普通失败不打扰用户 ----------

    @Test
    fun normalResponseIsOrdinary() {
        val f = cls(200, """{"ret":0,"data":{"albums":[]}}""")
        assertTrue(f is VerificationRecovery.Failure.Ordinary)
    }

    @Test
    fun notFoundIsOrdinary() {
        val f = cls(404, "not found")
        assertTrue(f is VerificationRecovery.Failure.Ordinary)
    }

    @Test
    fun serverErrorIsOrdinary() {
        val f = cls(500, "internal error")
        assertTrue(f is VerificationRecovery.Failure.Ordinary)
    }

    // ---------- 编排 ----------

    @Test
    fun successfulAttemptParsesDirectly() {
        kotlinx.coroutines.runBlocking {
            val r = VerificationRecovery.runWithRecovery(
                attempt = { 200 to """{"ok":true}""" },
                shouldLogin = { true },
                parse = { it.contains("ok") },
            )
            assertTrue(r.isSuccess)
            assertEquals(true, r.getOrNull())
        }
    }

    @Test
    fun verificationFailureSurfacesTypeAndHint() {
        kotlinx.coroutines.runBlocking {
            val r = VerificationRecovery.runWithRecovery(
                attempt = { 200 to """{"ret":407,"msg":"webtk缺失"}""" },
                shouldLogin = { false },
                parse = { it },
            )
            assertTrue(r.isFailure)
            val e = r.exceptionOrNull()
            assertTrue(e is VerificationRecovery.VerificationRequired)
            assertTrue((e as VerificationRecovery.VerificationRequired).loginUrl != null, "应给出登录地址")
        }
    }

    @Test
    fun verificationRequiredHasReadableMessage() {
        kotlinx.coroutines.runBlocking {
            val r = VerificationRecovery.runWithRecovery(
                attempt = { 200 to """<div class="geetest">Slide to complete the puzzle</div>""" },
                shouldLogin = { true },
                parse = { it },
            )
            val msg = r.exceptionOrNull()?.message ?: ""
            assertTrue(msg.contains("滑块"), "消息应告诉用户要拖滑块：$msg")
        }
    }
}
