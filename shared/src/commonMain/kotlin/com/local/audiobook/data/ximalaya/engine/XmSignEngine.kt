package com.local.audiobook.data.ximalaya.engine

/**
 * ============================================================
 *  xm-sign 签名引擎（隔离模块 · 单文件 · commonMain）
 * ============================================================
 *
 * 【隔离约定】—— 改这个文件之前先读这段
 *  1. 本文件**只做一件事**：把 (路径, 参数, cookie, 时间) 变成签名参数。
 *  2. 它**不允许**碰网络、不允许碰登录状态、不允许打日志。
 *  3. 项目里所有直连请求只能通过 `XimalayaApiClient`，而它只从这里取签名。
 *     别处禁止自己拼 `xm-sign` / `sign` / `token` 参数。
 *  4. **官方改签名算法时，修复路径 = 只改这一个文件，重新打包。** 其它代码一行不动。
 *  5. 签名规则本身随官方变化，这里实现的是"结构正确的通用版"，
 *     真机若返回签名错误，按第 4 条只改这里。
 *
 * 【参考】RSSHub 的 ximalaya 路由（MIT License, https://github.com/DIYgod/RSSHub）
 *  —— 仅借鉴其"参数排序 + 时间戳 + 摘要"的结构思路，代码为本项目重写。
 *
 * 【同步纪律 §19.7.4】commonMain 引擎 ↔ ximalaya-bridge upstream.py：改一处同步另一处。
 *  （桥当前无签名代码——播放接口走 xmSignType=1 无 xm-sign 参数；桥侧引入签名时以此为准。）
 *
 * 【迁移记录 T03】自安卓 data/ximalaya/engine 搬入 commonMain：
 *  javax.crypto/java.security → Crypto（纯 Kotlin，RFC 向量单测钉死），逻辑零改动。
 */
object XmSignEngine {

    /** 官方前端使用的固定前缀（随版本变化，改签名只需改这里） */
    private const val SIGN_PREFIX = "xmly"

    /** 签名结果里会写进去的字段名 */
    const val PARAM_SIGN = "xm-sign"

    /** 生成签名参数（同样的输入必须得到同样的输出，时间可注入）。 */
    fun sign(
        path: String,
        params: Map<String, String>,
        cookies: Map<String, String>,
        nowMs: Long,
    ): Map<String, String> {
        val sortedQuery = params.entries
            .sortedBy { it.key }
            .joinToString("&") { "${it.key}=${it.value}" }

        val token = cookies[XimalayaSessionRulesMirror.KEY_TOKEN] ?: ""
        val ts = nowMs.toString()

        val raw = SIGN_PREFIX + path + sortedQuery + token + ts
        val digestHex = Crypto.md5Hex(raw)
        val hmacHex = Crypto.hmacSha1Hex(raw, token.ifEmpty { SIGN_PREFIX })

        return mapOf(PARAM_SIGN to "${ts}~${digestHex.take(16)}~${hmacHex.take(16)}")
    }

    /** 计算签名用的摘要串（暴露出来供单测断言结构，不参与业务） */
    fun signatureMaterial(
        path: String,
        params: Map<String, String>,
        cookies: Map<String, String>,
        nowMs: Long,
    ): String {
        val sortedQuery = params.entries
            .sortedBy { it.key }
            .joinToString("&") { "${it.key}=${it.value}" }
        val token = cookies[XimalayaSessionRulesMirror.KEY_TOKEN] ?: ""
        return SIGN_PREFIX + path + sortedQuery + token + nowMs
    }
}

/**
 * 引擎对"关键 cookie 名"的镜像常量（不反向依赖业务包，两边值一致有单测断言）。
 */
object XimalayaSessionRulesMirror {
    const val KEY_TOKEN = "1&_token"
}
