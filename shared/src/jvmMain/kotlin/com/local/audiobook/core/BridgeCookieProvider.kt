package com.local.audiobook.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.file.Files
import java.nio.file.Path

// JVM spike 凭据来源（lead 拍板）：读桥持会话的 cookie 文件（与 bridge upstream._load_cookies 同构的扁平 {name:value}）。
// 纪律：路径走环境变量 BRIDGE_COOKIE_FILE（默认桥标准路径）；cookie 值绝不打日志、不进 git/文档。
class BridgeCookieProvider(
    private val filePath: String = System.getenv("BRIDGE_COOKIE_FILE") ?: "<bridge-path>/data/cookies.json",
) : CookieProvider {

    private var cache: String? = null
    private var loaded = false
    private var loadedNames: List<String> = emptyList()   // 只记字段名（桥同款纪律：日志只打字段名）

    override suspend fun cookie(): String? {
        if (!loaded) load()
        return cache
    }

    // 失效刷新：清缓存，下次 cookie() 重读文件；桥侧会话续期由桥的登录流程负责（App 侧不代登录）
    override suspend fun refresh() {
        loaded = false
        cache = null
    }

    fun loadedCookieNames(): List<String> = loadedNames   // 供诊断：只出名字，不出值

    private fun load() {
        loaded = true
        cache = runCatching {
            val text = Files.readString(Path.of(filePath))
            val obj = Json.parseToJsonElement(text) as? JsonObject ?: return@runCatching null
            val pairs = obj.entries.mapNotNull { (k, v) ->
                val s = (v as? JsonPrimitive)?.content
                if (s.isNullOrEmpty()) null else k + "=" + s
            }
            loadedNames = obj.keys.sorted()
            if (pairs.isEmpty()) null else pairs.joinToString("; ")
        }.getOrNull()
    }
}
