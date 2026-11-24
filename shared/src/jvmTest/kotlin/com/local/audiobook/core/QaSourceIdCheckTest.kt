package com.local.audiobook.core

import com.local.audiobook.core.engine.SearchEngine
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.engine.WebSearchBudget
import com.local.audiobook.data.ximalaya.RequestThrottle
import kotlinx.coroutines.runBlocking
import kotlin.test.Test

class QaSourceIdCheckTest {
    @Test
    fun engineDefaultSourceId() = runBlocking {
        val fake = object : JsonFetcher {
            override suspend fun get(url: String, headers: Map<String, String>) = FetchOutcome.Ok(200, "{}")
        }
        val now = { 0L }
        val engine = SearchEngine(fetcher = fake, throttle = RequestThrottle(0L) { 0L }, budget = WebSearchBudget(now = now))
        println("SearchEngine默认sourceId=[" + engine.sourceId + "]")
    }
}