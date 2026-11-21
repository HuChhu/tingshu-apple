package com.local.audiobook.core.net

sealed interface FetchOutcome {
    data class Ok(val httpStatus: Int, val text: String) : FetchOutcome
    data class Failed(val kind: String, val detail: String) : FetchOutcome
}

interface JsonFetcher {
    suspend fun get(url: String, headers: Map<String, String>): FetchOutcome
}
