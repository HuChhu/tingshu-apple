package com.local.audiobook.core.engine

import com.local.audiobook.core.SourceErrors

/**
 * ============================================================
 *  验证恢复机制（Verification Recovery）
 * ============================================================
 *
 * 【设计来源】参考「我的听书」的 SearchVerificationActivity：
 *   请求被源站风控拦住时，不让用户干瞪眼，而是：
 *     ① 识别出「这是验证拦截」而不是「真的没结果」
 *     ② 拉起 WebView 让用户人工过验证（滑块/点选/登录）
 *     ③ 过完后自动把 cookie 回填，**重试原请求**
 *     ④ 仍失败则明确告诉用户是哪一步没过
 *
 * 【为什么必须做】
 *   我们实测过喜马拉雅的三道门：
 *     - 搜索：{"reason":"risk invalid","riskLevel":5}
 *     - 专辑：{"ret":407,"msg":"webtk缺失"}
 *     - 登录：极验滑块 "Slide to complete the puzzle"
 *   这些都不是「代码写错了」，是「需要真人过一关」。
 *   没有恢复机制，用户只能反复重试撞运气。
 *
 * 【纪律】
 *   ① 只在识别为「验证类失败」时才要求人工介入，不滥用
 *   ② 恢复后重试**有上限**（默认 2 次），防死循环
 *   ③ 每次失败都保留原因，最后一次性告诉用户
 *   ④ 不自己猜验证结果，一切以 cookie / 响应判定为准
 */
object VerificationRecovery {

    /** 需要用户介入的类型 */
    enum class VerificationType(val userHint: String) {
        Slider("需要拖动滑块完成验证"),
        ClickSelect("需要按顺序点击图中文字"),
        Login("需要登录账号"),
        Captcha("需要输入验证码"),
        Unknown("需要完成人机验证"),
    }

    /** 一次请求失败的分类结果 */
    sealed class Failure {
        /** 可以重试的验证类失败 */
        data class NeedsVerification(
            val type: VerificationType,
            val detail: String,
            val loginUrl: String? = null,
        ) : Failure()

        /** 普通失败（网络、404、解析错），不需要人工 */
        data class Ordinary(val reason: String, val error: SourceErrors? = null) : Failure()

        /** 全部重试后的终态 */
        data class GaveUp(val attempts: Int, val lastDetail: String) : Failure()
    }

    /**
     * 从响应文本判断是否属于「需要人工验证」。
     *
     * 判据（全部来自实测）：
     *   - 喜马拉雅搜索风控：contains("risk invalid") 或 riskLevel >= 3
     *   - webtk 缺失：contains("webtk缺失") 或 ret == 407
     *   - 极验：contains("geetest") 或 "Slide to complete"
     *   - 通用登录墙：ret == 401 / isNeedLogin == true / status == 485
     *   - 明文「登录」「验证」字样 + 短响应
     */
    fun classify(httpStatus: Int, body: String): Failure {
        val b = body.lowercase()

        // 1. 喜马拉雅搜索风控
        if (b.contains("risk invalid") || Regex(""""riskLevel"\s*:\s*([3-9])""").containsMatchIn(body)) {
            return Failure.NeedsVerification(
                VerificationType.Login,
                detail = "搜索被风控拦截（riskLevel≥3）",
                loginUrl = "https://passport.ximalaya.com/page/m/login",
            )
        }

        // 2. webtk 缺失
        if (b.contains("webtk缺失") || Regex(""""ret"\s*:\s*407""").containsMatchIn(body)) {
            return Failure.NeedsVerification(
                VerificationType.Login,
                detail = "缺少 webtk 令牌（需登录后由页面生成）",
                loginUrl = "https://passport.ximalaya.com/page/m/login",
            )
        }

        // 3. 极验
        if (b.contains("geetest") || b.contains("slide to complete") || b.contains("select in this order")) {
            val type = if (b.contains("select in this order")) VerificationType.ClickSelect else VerificationType.Slider
            return Failure.NeedsVerification(type, detail = "出现极验人机验证")
        }

        // 4. 登录墙
        if (httpStatus == 401 || httpStatus == 403 ||
            Regex(""""ret"\s*:\s*401""").containsMatchIn(body) ||
            Regex(""""status"\s*:\s*485""").containsMatchIn(body) ||
            Regex(""""isNeedLogin"\s*:\s*true""").containsMatchIn(body) ||
            b.contains("需要登录") || b.contains("请先登录") || b.contains("登录后")
        ) {
            return Failure.NeedsVerification(
                VerificationType.Login,
                detail = "接口要求登录态",
                loginUrl = "https://passport.ximalaya.com/page/m/login",
            )
        }

        // 5. 通用验证码
        if (b.contains("验证码") || b.contains("captcha") || b.contains("人机验证")) {
            return Failure.NeedsVerification(VerificationType.Captcha, detail = "要求输入验证码")
        }

        // 6. 普通失败
        return Failure.Ordinary("非验证类失败（HTTP $httpStatus）")
    }

    /**
     * 带恢复的重试编排。
     *
     * @param attempt     执行一次请求；返回 (httpStatus, body)
     * @param shouldLogin 是否需要先登录（读当前登录态）
     * @param maxRetries  最多重试几次（默认 2）
     */
    suspend fun <T> runWithRecovery(
        maxRetries: Int = 2,
        attempt: suspend () -> Pair<Int, String>,
        shouldLogin: () -> Boolean,
        parse: (String) -> T,
    ): Result<T> {
        var lastDetail = ""
        var currentLoginUrl: String? = null

        for (round in 0..maxRetries) {
            val (status, body) = attempt()

            when (val f = classify(status, body)) {
                is Failure.NeedsVerification -> {
                    lastDetail = f.detail
                    currentLoginUrl = f.loginUrl
                    // 已经是登录态还要求验证 → 说明是滑块/验证码，需要用户先过
                    // 未登录 → 提示去登录
                    if (round == maxRetries) {
                        return Result.failure(
                            VerificationRequired(f.type, f.detail, currentLoginUrl, round + 1)
                        )
                    }
                    // 停止重试，等用户完成验证后再调一次
                    // 这里不自动弹 WebView（平台层负责），只返回「需要什么」
                    return Result.failure(
                        VerificationRequired(f.type, f.detail, currentLoginUrl, round + 1)
                    )
                }
                is Failure.Ordinary -> {
                    return try { Result.success(parse(body)) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) { Result.failure(e) }
                }
                is Failure.GaveUp -> {
                    lastDetail = f.lastDetail
                }
            }
        }

        return Result.failure(VerificationRequired(VerificationType.Unknown, lastDetail, currentLoginUrl, maxRetries + 1))
    }

    /** 需要平台层拉起 WebView 完成的验证 */
    class VerificationRequired(
        val type: VerificationType,
        val detail: String,
        val loginUrl: String?,
        val attempts: Int,
    ) : Exception("${type.userHint}（$detail）")
}
