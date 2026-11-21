package com.local.audiobook.core.engine

// 对拍基准：bridge api.py 的 URL 模板 + UA（bridge 是我们的代码）
object SearchRoutes {
    const val MOBILE_BASE = "https://mobile.ximalaya.com"
    const val WEB_BASE = "https://www.ximalaya.com"
    const val MOBILE_UA = "ting_6.6.90(Galaxy,Android15)"
    const val WEB_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    const val IMAGE_CDN = "https://<cdn>/"

    fun mobileSearch(kw: String, page: Int, rows: Int) =
        MOBILE_BASE + "/mobile-search-search-words-mobile/android/search?kw=" + enc(kw) + "&page=" + page + "&rows=" + rows

    fun webSearch(kw: String, page: Int, rows: Int) =
        WEB_BASE + "/revision/search/main?core=album&kw=" + enc(kw) + "&page=" + page +
            "&spellchecker=true&rows=" + rows + "&condition=relation&device=iPhone"

    fun categoryAlbums(categoryId: Long, pageNum: Int, pageSize: Int) =
        WEB_BASE + "/revision/category/v2/albums?categoryId=" + categoryId + "&pageNum=" + pageNum + "&pageSize=" + pageSize + "&sort=1"

    fun albumUrl(albumId: Long) = WEB_BASE + "/album/" + albumId

    fun coverUrl(path: String) = when {
        path.startsWith("http") -> path
        path.isEmpty() -> ""
        else -> IMAGE_CDN + path.trimStart('/')
    }

    // UTF-8 百分号编码（commonMain 纯实现）
    fun enc(s: String): String {
        val out = StringBuilder()
        val hex = "0123456789ABCDEF"
        for (byte in s.encodeToByteArray()) {
            val b = byte.toInt() and 0xFF
            val c = b.toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_' || c == '.' || c == '~') out.append(c)
            else { out.append('%'); out.append(hex[b shr 4]); out.append(hex[b and 0x0F]) }
        }
        return out.toString()
    }
}
