package com.local.audiobook.data.ximalaya

import com.local.audiobook.core.SourceErrors
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * 直连请求的结果模型 + 错误分类（纯函数，可单测）。
 *
 * 三种失败必须区分清楚，因为用户看到的话术和"接下来该干什么"完全不同：
 *  - NOT_LOGGED_IN  → 去登录
 *  - RISK_CONTROL   → 等一会儿（有冷却），别连点
 *  - API_CHANGED    → 该更新 App 了
 *  - NETWORK        → 检查网络
 */
sealed interface XimalayaResult<out T> {
    data class Ok<T>(val value: T) : XimalayaResult<T>
    data class Fail(val kind: ErrorKind, val detail: String = "") : XimalayaResult<Nothing>
}

enum class ErrorKind {
    NOT_LOGGED_IN, RISK_CONTROL, API_CHANGED, NETWORK, ENCRYPTED_AUDIO, UNKNOWN,
}

/** 把错误类型翻译成给用户看的话（纯函数） */
fun ErrorKind.userMessage(): String = when (this) {
    ErrorKind.NOT_LOGGED_IN -> "未登录或登录已过期，去登录"
    ErrorKind.RISK_CONTROL -> "触发了平台风控，请稍后再试"
    ErrorKind.API_CHANGED -> "接口已变更，可能需要更新 App"
    ErrorKind.NETWORK -> "网络不可用，检查一下网络"
    ErrorKind.ENCRYPTED_AUDIO -> "该音频为付费加密格式，暂不支持播放"
    ErrorKind.UNKNOWN -> "出了一点问题，稍后再试"
}

/**
 * 统一错误分类器（禁双实现漂移：安卓版与引擎版在此合一）。
 *
 * 判定顺序对齐 bridge upstream._classify（行为基线）：风控最先（一票否决），其次登录，再业务码。
 * 安卓原实现是"登录先于风控"——两信号同时出现的边角案例按 bridge 序（记录于迁移日志）。
 * 引擎侧新增 riskLevel>=3 判据（bridge 同款超集），安卓调用点已同步传参。
 */
object ErrorClassifier {

    /** 原语分类（安卓调用面；riskLevel 为 bridge 超集判据，默认 null 不改变旧行为） */
    fun classify(
        httpCode: Int,
        ret: Int?,
        isNeedLogin: Boolean?,
        reason: String?,
        riskLevel: Int? = null,
    ): ErrorKind? {
        if (httpCode == 0) return ErrorKind.NETWORK
        val r = (reason ?: "").lowercase()
        if (r.contains("risk") || r.contains("验证") || r.contains("illegal") || (riskLevel != null && riskLevel >= 3)) {
            return ErrorKind.RISK_CONTROL
        }
        if (isNeedLogin == true || ret == 401 || ret == 402) return ErrorKind.NOT_LOGGED_IN
        // 【2026-11-25】4xx 以前落到 `return null`（= 当成功处理），
        // 于是 /revision/play/v1/audio 返回 404 时既不说“接口没了”、也不报错，
        // 而是继续往下取 data，最后抛一句「上游未返回可播放地址」——误诊的源头。
        // 现在 4xx 一律算接口改版（401/402 上面已经先判成“未登录”）。
        if (httpCode in 400..499) return ErrorKind.API_CHANGED
        if (httpCode in 500..599) return ErrorKind.API_CHANGED
        if (httpCode == 200 && ret != null && ret != 0 && ret != 200) return ErrorKind.API_CHANGED
        return null
    }

    /** 判断播放地址是否是加密音频（.xm） */
    fun isEncryptedAudio(url: String?): Boolean =
        url != null && url.lowercase().substringBefore('?').endsWith(".xm")

    // ---------- 引擎适配面（桥对齐；M1/M2 分类矩阵由此保持逐字节一致） ----------

    private fun prim(o: JsonObject?, key: String): JsonPrimitive? {
        val v = o?.get(key) ?: return null
        return if (v is JsonNull) null else v as? JsonPrimitive
    }

    /**
     * JsonObject 分类（引擎调用面）：返回 (bridge 语义状态, 契约错误)。
     * 状态: ok / risk / need_login / http_error —— 与 M1/M2 对拍基线一致：
     *   risk-web→(risk,RateLimited) / need-login→(need_login,Auth) /
     *   ret:50→(http_error,Upstream(50)) / ret:924→(http_error,Upstream(924)) / category→ok
     */
    fun classifyJson(httpStatus: Int, obj: JsonObject?): Pair<String, SourceErrors?> {
        if (obj == null) return "ok" to null
        val inner = obj["data"] as? JsonObject
        val reason = prim(inner, "reason")?.content
        val riskLevel = prim(inner, "riskLevel")?.content?.trim()?.toIntOrNull()
        val ret = prim(obj, "ret")?.content?.trim()?.toIntOrNull()
        val needLogin = prim(obj, "isNeedLogin")?.content?.let { it == "true" }
        return when (classify(httpStatus, ret, needLogin, reason, riskLevel)) {
            null -> "ok" to null
            ErrorKind.RISK_CONTROL -> "risk" to SourceErrors.RateLimited(needVerification = true)
            ErrorKind.NOT_LOGGED_IN -> "need_login" to SourceErrors.Auth("需要登录")
            ErrorKind.API_CHANGED -> "http_error" to SourceErrors.Upstream(ret ?: httpStatus)
            ErrorKind.NETWORK -> "http_error" to SourceErrors.Network("网络层失败")
            ErrorKind.ENCRYPTED_AUDIO, ErrorKind.UNKNOWN ->
                "http_error" to SourceErrors.ParseFailed("分类异常：" + kindName())
        }
    }

    private fun kindName() = "UNKNOWN"
}
