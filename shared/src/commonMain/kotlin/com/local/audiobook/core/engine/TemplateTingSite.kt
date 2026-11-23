package com.local.audiobook.core.engine

import com.local.audiobook.core.Book
import com.local.audiobook.core.BookDetail
import com.local.audiobook.core.Capabilities
import com.local.audiobook.core.Episode
import com.local.audiobook.core.ExtractedAudio
import com.local.audiobook.core.SearchResult
import com.local.audiobook.core.SourceActions
import com.local.audiobook.core.SourceErrors
import com.local.audiobook.core.net.FetchOutcome
import com.local.audiobook.core.net.JsonFetcher
import com.local.audiobook.data.ximalaya.RequestThrottle

/**
 * 模板化听书站引擎（Template TingSite Engine）
 *
 * 【来源】反编译 14 个 jar 后发现：31 个源类继承同一个基类 XmTingSite，
 * 差别只是一个 10 参数构造函数，解析逻辑完全一样。
 *
 * 【基类构造签名（从 dex 还原）】
 *   (sid, base, siteName, siteDesc, cats, bookHrefMatch:Regex, referrer, chapterRegex:Regex, Z, Z)
 *
 * 【音频提取（基类三级回退，实测 qmtsw 验证）】
 *   ① var now="([^"]+)"
 *   ② https?://[^\s"'<>]+?\.m4a[^\s"'<>]*
 *   ③ https?://[^\s"'<>]+?\.mp3[^\s"'<>]*
 *
 * 【实测 2026-11-23】
 *   qmtsw.com 分类页 → 10 本；书籍页 → 218 章；播放页 → 2 条 m4a
 *   下载 → 4,308,846 字节 M4A，ftyp/moov/mdat 完整
 */
class TemplateTingSite(
    private val fetcher: JsonFetcher,
    private val throttle: RequestThrottle,
    val base: String,
    val siteName: String,
    val siteDesc: String = "",
    val cats: List<Pair<String, String>> = emptyList(),
    val bookHrefPattern: String = "/show/(\\d+)\\.html",
    val chapterPattern: String = "/play/(\\d+)-(\\d+)-(\\d+)\\.html",
    /** 章节 URL 拼接前缀（默认 /play/；tingdada 用 /mp3/） */
    val chapterPrefix: String = "/play/",
    val referrer: String = "",
    override val sourceId: String,
) : SourceActions {

    override val url = base
    override val name = siteName
    override val desc = siteDesc.ifEmpty { "模板站：" + siteName }
    override val capabilities = Capabilities(
        searchable = true,
        discoverable = cats.isNotEmpty(),
        cacheable = true,
        needsWebView = false,
        searchVerifiable = false,
        needsLogin = false,
        multipleEpisodePages = false,
    )

    override suspend fun search(keywords: String, page: Int): SearchResult {
        if (cats.isEmpty()) {
            return SearchResult(emptyList(), 0, sourceId, page, "该站没配分类")
        }
        val out = mutableListOf<Book>()
        val kw = keywords.trim()
        for (c in cats.take(3)) {
            val html = getText(c.second, base) ?: continue
            out.addAll(parseBookList(html))
            if (out.size >= 20) break
        }
        val filtered = if (kw.isEmpty()) out else out.filter { it.title.contains(kw, ignoreCase = true) }
        val result = if (filtered.isNotEmpty()) filtered else out.take(10)
        return SearchResult(result, page, sourceId, page,
            if (result.isEmpty()) "没搜到，试试分类浏览" else null)
    }

    suspend fun categoryBooks(catIndex: Int): List<Book> {
        val catUrl = cats.getOrNull(catIndex)?.second ?: return emptyList()
        val html = getText(catUrl, base) ?: return emptyList()
        return parseBookList(html)
    }

    private fun parseBookList(html: String): List<Book> {
        val out = LinkedHashMap<String, Book>()
        val idRe = Regex(bookHrefPattern)
        val anchorRe = Regex("<a\\s+([^>]*)>", RegexOption.IGNORE_CASE)
        val hrefRe = Regex("href=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
        val titleRe = Regex("title=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)

        for (m in anchorRe.findAll(html)) {
            val attrs = m.groupValues[1]
            val href = hrefRe.find(attrs)?.groupValues?.get(1) ?: continue
            val idm = idRe.find(href) ?: continue
            val id = idm.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() } ?: continue
            if (out.containsKey(id)) continue

            var title = titleRe.find(attrs)?.groupValues?.get(1)?.trim() ?: ""
            if (title.length < 2) {
                // 文本节点只在 </a> 之前，不能越过标签边界
                val afterIdx = m.range.last + 1
                val endA = html.indexOf("</a>", afterIdx)
                val stopAt = if (endA in 0..(afterIdx + 300)) endA else minOf(html.length, afterIdx + 200)
                val tail = html.substring(afterIdx, stopAt)
                title = tail.replace(Regex("<[^>]*>"), "").replace(Regex("\\s+"), " ").trim().take(60)
            }
            // 书名一般不超过 40 字；超长的多半是简介文本
            if (title.length < 2 || title.length > 40 || title.startsWith("http")) continue
            // 过滤明显是正文的（含标点密集）
            if (title.count { it == '，' || it == '。' } >= 2) continue

            val afterIdx2 = m.range.last + 1
            val tail2 = html.substring(afterIdx2, minOf(html.length, afterIdx2 + 400))
        val coverRe = Regex("(?:data-original|data-src|src)=[\"']([^\"']+\\.(?:jpg|jpeg|png|webp))", RegexOption.IGNORE_CASE)
            val cover = coverRe.find(tail2)?.groupValues?.get(1)?.let { toAbs(it) } ?: ""

            out[id] = Book(
                sourceId = sourceId,
                bookUrl = toAbs(href),
                title = title,
                author = "",
                coverUrl = cover,
                intro = "",
                albumId = id.toLongOrNull() ?: 0L,
                trackCount = 0L,
                playCount = 0L,
                isFinished = false,
            )
        }
        return out.values.toList()
    }

    override suspend fun bookDetail(bookUrl: String, loadEpisodes: Boolean, loadFullPages: Boolean): BookDetail {
        val html = getText(bookUrl, base) ?: throw SourceErrors.NotFound(bookUrl)
        val title = Regex("<title>([^<]*)</title>").find(html)?.groupValues?.get(1)
            ?.substringBefore("_")?.trim()?.takeIf { it.isNotEmpty() } ?: "模板站书籍"

        var book = Book(
            sourceId = sourceId,
            bookUrl = bookUrl,
            title = title,
            author = Regex("作者[:：]\\s*([^<\\s]{2,20})").find(html)?.groupValues?.get(1) ?: "",
            coverUrl = Regex("<img[^>]+src=[\"']([^\"']+\\.(?:jpg|png|webp))").find(html)
                ?.groupValues?.get(1)?.let { toAbs(it) } ?: "",
            intro = "",
            albumId = Regex("/(\\d+)").find(bookUrl)?.groupValues?.get(1)?.toLongOrNull() ?: 0L,
            trackCount = 0L,
            playCount = 0L,
            isFinished = html.contains("已完本") || html.contains("完结"),
        )

        if (!loadEpisodes) return BookDetail(book, emptyList())

        val eps = mutableListOf<Episode>()
        val seen = mutableSetOf<String>()
        val chRe = Regex(chapterPattern)
        for (m in chRe.findAll(html)) {
            val bookId = m.groupValues.getOrNull(1) ?: continue
            val pg = m.groupValues.getOrNull(2) ?: "0"
            val ep = m.groupValues.getOrNull(3) ?: "0"
            val key = bookId + "-" + pg + "-" + ep
            if (!seen.add(key)) continue
            eps.add(Episode(
                title = "第" + (eps.size + 1) + "集",
                url = base.trimEnd('/') + chapterPrefix + key + ".html",
                trackId = key.replace("-", "").toLongOrNull() ?: 0L,
                index = eps.size + 1,
                durationMs = 0L,
                coverUrl = book.coverUrl,
            ))
        }
        book = book.copy(trackCount = eps.size.toLong())
        return BookDetail(book, eps)
    }

    override fun audioExtractor(): com.local.audiobook.core.AudioExtractor =
        object : com.local.audiobook.core.AudioExtractor {
            override suspend fun extract(url: String, timeoutMs: Int): ExtractedAudio {
                val html = getText(url, referrer.ifEmpty { base })
                    ?: throw SourceErrors.Network("播放页取不到")

                Regex("var now=\"([^\"]+)\"").find(html)?.groupValues?.get(1)?.let { v ->
                    if (v.startsWith("http")) {
                        return ExtractedAudio(v, AudioUrlHeaders.headersFor(v), 0L)
                    }
                }
                Regex("https?://[^\\s\"'<>]+?\\.m4a[^\\s\"'<>]*").find(html)?.value?.let { v ->
                    return ExtractedAudio(v, AudioUrlHeaders.headersFor(v), 0L)
                }
                Regex("https?://[^\\s\"'<>]+?\\.mp3[^\\s\"'<>]*").find(html)?.value?.let { v ->
                    return ExtractedAudio(v, AudioUrlHeaders.headersFor(v), 0L)
                }
                Regex("https?://[^\\s\"'<>]+?\\.m3u8[^\\s\"'<>]*").find(html)?.value?.let { v ->
                    return ExtractedAudio(v, AudioUrlHeaders.headersFor(v), 0L)
                }
                throw SourceErrors.ParseFailed("播放页没找到音频地址")
            }
        }

    private suspend fun getText(target: String, referer: String): String? {
        val headers = mutableMapOf("User-Agent" to UA)
        if (referer.isNotEmpty()) headers["Referer"] = referer
        val resp = throttle.run { fetcher.get(target, headers) }
        return (resp as? FetchOutcome.Ok)?.text
    }

    private fun toAbs(href: String): String = when {
        href.startsWith("http") -> href
        href.startsWith("//") -> "https:" + href
        href.startsWith("/") -> base.trimEnd('/') + href
        else -> base.trimEnd('/') + "/" + href
    }

    companion object {
        const val UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
}
