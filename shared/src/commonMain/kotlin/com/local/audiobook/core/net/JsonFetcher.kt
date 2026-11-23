package com.local.audiobook.core.net

sealed interface FetchOutcome {
    data class Ok(val httpStatus: Int, val text: String) : FetchOutcome
    data class Failed(val kind: String, val detail: String) : FetchOutcome
}

interface JsonFetcher {
    suspend fun get(url: String, headers: Map<String, String>): FetchOutcome

    /**
     * POST 表单。默认实现退回 GET（iOS 壳的 IosJsonFetcher 尚未实现 POST 时
     * 至少不会编译不过 —— 调用方拿到的结果会像"没登录/接口拒绝"一样被跳过）。
     */
    suspend fun post(url: String, headers: Map<String, String>, form: Map<String, String>): FetchOutcome =
        get(url, headers)
}
