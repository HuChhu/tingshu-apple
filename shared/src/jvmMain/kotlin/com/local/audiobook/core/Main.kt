package com.local.audiobook.core

import com.local.audiobook.core.engine.*
import com.local.audiobook.data.ximalaya.ErrorClassifier
import com.local.audiobook.data.ximalaya.RequestThrottle
import com.local.audiobook.core.net.KtorJsonFetcher
import io.ktor.client.*
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.io.FileOutputStream
import java.io.PrintStream
import java.nio.file.Files
import java.nio.file.Path

private val out = PrintStream(FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8")

// M2 spike 命令行（验收表 M2：打印可播 URL；URL HTTP 200 且音频 Content-Type）
//   search <关键词> [页码]
//   discover [类目ID] [页码] [条数]
//   detail <albumId|bookUrl> [全翻页 true/false]   —— 动作二（需登录 Cookie）
//   extract <trackId|soundUrl|audioUrl>            —— 动作三（级1→级3）
//   fixture <文件> <classify|category|tracks|play> —— 离线对拍（fixtures/ 与 fixtures/constructed/）
suspend fun main(args: Array<String>) {
    val mode = args.getOrNull(0) ?: return out.print(usage())
    if (mode == "fixture") return fixture(args.getOrElse(1) { "" }, args.getOrElse(2) { "" },
        args.getOrNull(3)?.toIntOrNull() ?: 1, args.getOrNull(4)?.toIntOrNull() ?: 30)

    val client = HttpClient(CIO) {
        followRedirects = true
        install(HttpTimeout) { requestTimeoutMillis = 15_000 }
    }
    val now = { System.nanoTime() / 1_000_000L }
    val cookieProvider = BridgeCookieProvider()
    val engine = SearchEngine(
        fetcher = KtorJsonFetcher(client),
        throttle = RequestThrottle(minIntervalMs = 1_000, clock = now),
        budget = WebSearchBudget(now = now),
        nowMs = { System.currentTimeMillis() },
        cookieProvider = cookieProvider,
    )
    when (mode) {
        "kuwo" -> runCatching {
            val kw = com.local.audiobook.core.engine.KuwoSource(
                fetcher = KtorJsonFetcher(client),
                throttle = RequestThrottle(minIntervalMs = 1_000, clock = now),
            )
            val op = args.getOrNull(1) ?: "search"
            when (op) {
                "search" -> {
                    val r = kw.search(args.getOrElse(2) { "三体" }, 1)
                    out.println("KUWO_SEARCH books=" + r.books.size)
                    for (b in r.books.take(5)) out.println("  [" + b.albumId + "] " + b.title + " | " + b.author + " | 集数:" + b.trackCount)
                }
                "detail" -> {
                    val d = kw.bookDetail(args.getOrElse(2) { "98108239" }, true, false)
                    out.println("KUWO_DETAIL title=" + d.book.title + " author=" + d.book.author + " eps=" + d.episodes.size)
                    for (e in d.episodes.take(3)) out.println("  #" + e.index + " " + e.title + " (" + e.durationMs/1000 + "s) rid=" + e.trackId)
                }
                "play" -> {
                    val a = kw.audioExtractor().extract(args.getOrElse(2) { "" })
                    out.println("KUWO_PLAY url=" + a.url)
                }
            }
        }.onFailure { out.println("ERROR " + it::class.simpleName + " " + it.message) }
        "open" -> runCatching {
            // 免登录源测试：open search <kw> | open detail <albumId>
            val op = args.getOrNull(1) ?: "search"
            val openEngine = com.local.audiobook.core.engine.XimalayaOpenSource(
                fetcher = KtorJsonFetcher(client),
                throttle = RequestThrottle(minIntervalMs = 1_000, clock = now),
            )
            when (op) {
                "search" -> {
                    val kw = args.getOrElse(2) { "三体" }
                    val r = openEngine.search(kw, 1)
                    out.println("OPEN_SEARCH kw=" + kw + " books=" + r.books.size + " maxPage=" + r.maxPage)
                    for (b in r.books.take(10)) {
                        out.println("  [" + b.albumId + "] " + b.title + " | 主播:" + b.author +
                            " | 播放:" + b.playCount + " | 集数:" + b.trackCount)
                    }
                    if (r.books.isEmpty()) out.println("  hint=" + r.hint)
                }
                "detail" -> {
                    val aid = args.getOrElse(2) { "41682166" }
                    val d = openEngine.bookDetail(aid, loadEpisodes = true, loadFullPages = true)
                    out.println("OPEN_DETAIL albumId=" + d.book.albumId + " title=" + d.book.title +
                        " author=" + d.book.author + " trackCount=" + d.book.trackCount +
                        " episodes=" + d.episodes.size)
                    for (e in d.episodes.take(5)) {
                        out.println("  #" + e.index + " " + e.title + " (" + (e.durationMs / 1000) + "s)")
                        out.println("     url=" + e.url.take(90))
                    }
                }
                "audio" -> {
                    val u = args.getOrElse(2) { "" }
                    val a = openEngine.audioExtractor().extract(u)
                    out.println("OPEN_AUDIO url=" + a.url)
                    out.println("OPEN_AUDIO headers=" + a.headers)
                }
            }
        }.onFailure { out.println("ERROR " + it::class.simpleName + " " + it.message) }
        "search" -> out.print(render(engine.search(args.getOrElse(1) { "三体" }, args.getOrNull(2)?.toIntOrNull() ?: 1)))
        "discover" -> out.print(render(engine.discover(
            categoryId = args.getOrNull(1)?.toLongOrNull() ?: 3L,
            pageNum = args.getOrNull(2)?.toIntOrNull() ?: 1,
            pageSize = args.getOrNull(3)?.toIntOrNull() ?: 12,
        )))
        "detail" -> runCatching {
            val full = args.getOrNull(2)?.toBooleanStrictOrNull() ?: false
            val d = engine.bookDetail(args.getOrElse(1) { "" }, loadEpisodes = true, loadFullPages = full)
            out.println("DETAIL albumId=" + d.book.albumId + " title=" + d.book.title +
                " author=" + d.book.author + " trackCount=" + d.book.trackCount +
                " loaded=" + d.episodes.size + " cookieNames=" + cookieProvider.loadedCookieNames())
            for (e in d.episodes.take(10)) out.println(trackRow(e))
            if (d.episodes.size > 10) out.println("TRACK ... 共 " + d.episodes.size + " 条")
        }.onFailure { out.println("ERROR kind=" + (it as? SourceErrors)?.let { e -> e::class.simpleName } + " reason=" + ((it as? SourceErrors)?.let { e -> e.toString() } ?: it.message)) }
        "extract" -> runCatching {
            val x = engine.audioExtractor().extract(args.getOrElse(1) { "" })
            out.println("EXTRACT url=" + x.url)
            out.println("EXTRACT headerKeys=" + x.headers.keys.joinToString(", "))
            out.println("EXTRACT expiresInSeconds=" + x.expiresInSeconds)
        }.onFailure { out.println("ERROR kind=" + (it as? SourceErrors)?.let { e -> e::class.simpleName } + " reason=" + ((it as? SourceErrors)?.let { e -> e.toString() } ?: it.message)) }
        else -> out.print(usage())
    }
}

private fun usage() = "用法: search <kw> [page] | discover [cat] [page] [size] | detail <albumId> [full] | extract <trackId|url> | fixture <file> <mode>\n"

private fun row(b: Book) = "BOOK albumId=" + b.albumId + "\ttitle=" + b.title.replace("\t", " ") +
    "\tauthor=" + b.author.replace("\t", " ") + "\tcover=" + b.coverUrl +
    "\ttrackCount=" + b.trackCount + "\tplayCount=" + b.playCount + "\n"

private fun trackRow(e: Episode) = "TRACK trackId=" + e.trackId + "\tindex=" + e.index +
    "\ttitle=" + e.title.replace("\t", " ") + "\tdurationMs=" + e.durationMs + "\tcover=" + e.coverUrl + "\n"

private fun render(r: SearchResult): String {
    val sb = StringBuilder()
    sb.append("RESULT source=" + r.source + " page=" + r.page + " maxPage=" + r.maxPage + "\n")
    if (r.hint != null) sb.append("HINT " + r.hint + "\n")
    for (b in r.books) sb.append(row(b))
    sb.append("COUNT books=" + r.books.size + "\n")
    return sb.toString()
}

private fun fixture(file: String, fm: String, page: Int, pageSize: Int) {
    if (file.isEmpty()) return out.print("fixture: 缺文件参数\n")
    val text = Files.readString(Path.of(file))
    val json = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
        ?: return out.print("fixture: 非JSON对象\n")
    when (fm) {
        "category" -> dumpBooks(AlbumExtractor.fromCategory(json, "fixture-src"), "category")
        "tracks" -> {
            val tp = TrackExtractor.fromDetail(json["data"] as? JsonObject ?: JsonObject(emptyMap()), page, pageSize, "fixture-src")
            for (e in tp.episodes) out.print(trackRow(e))
            out.println("COUNT tracks=" + tp.episodes.size + " page=" + page + " pageSize=" + pageSize +
                " totalCount=" + tp.totalCount + " maxPageId=" + tp.maxPageId +
                " computedMaxPage=" + TrackNormalizer.maxPage(tp.totalCount, pageSize))
        }
        "play" -> {
            val inner = json["data"] as? JsonObject
            val audioUrl = AlbumNormalizer.str(inner, "src", "url", "playUrl")
            val hs = AudioUrlHeaders.headersFor(audioUrl)
            out.println("EXTRACT url=" + audioUrl)
            out.println("EXTRACT headerKeys=" + hs.keys.joinToString(", "))
            out.println("EXTRACT expiresInSeconds=" + if (audioUrl.isEmpty()) 0 else 3600)
        }
        "classify" -> {
            val (status, err) = ErrorClassifier.classifyJson(200, json)
            out.println("CLASSIFY status=" + status + " error=" + (err?.let { it::class.simpleName } ?: "null"))
        }
        else -> out.print("fixture mode: classify|category|tracks|play\n")
    }
}

private fun dumpBooks(books: List<Book>, mode: String) {
    for (b in books) out.print(row(b))
    out.print("COUNT books=" + books.size + " mode=" + mode + "\n")
}
