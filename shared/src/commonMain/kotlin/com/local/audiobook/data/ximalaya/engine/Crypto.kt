package com.local.audiobook.data.ximalaya.engine

/**
 * 纯 Kotlin 密码学原语（commonMain，零平台 API、零新增 actual——契约 C3 触点保持 0）。
 * 正确性由 RFC 1321/RFC 3174/RFC 2104 测试向量 + python hashlib 对拍单测钉死。
 * 仅服务签名引擎（MD5/HMAC-SHA1），不是通用密码库。
 */
object Crypto {

    fun md5Hex(input: String): String = md5(input.encodeToByteArray()).toHexLE()   // MD5 摘要字节序=每字小端

    /** 每字按小端展开成十六进制（MD5 用；SHA-1/HMAC 用大端 toHex） */
    private fun IntArray.toHexLE(): String {
        val sb = StringBuilder(size * 8)
        val HEX = "0123456789abcdef"
        for (word in this) {
            for (shift in listOf(0, 8, 16, 24)) {
                sb.append(HEX[((word ushr (shift + 4)) and 0x0F)])
                sb.append(HEX[(word ushr shift) and 0x0F])
            }
        }
        return sb.toString()
    }

    fun hmacSha1Hex(input: String, key: String): String =
        hmacSha1(input.encodeToByteArray(), key.encodeToByteArray()).toHex()

    /**
     * HMAC-MD5，输出小写 hex。
     *
     * 【用途】蜻蜓 FM 的音频地址签名（反编译 QingTingFM$getAudioUrlExtractor$1 得到）
     *
     * 【RFC 2104 标准结构】
     *   blockSize = 64（MD5 的块大小）
     *   K' = key 长度 > 64 ? md5(key) : key，右侧补 0 到 64 字节
     *   ipad = 0x36 重复 64 次
     *   opad = 0x5C 重复 64 次
     *   HMAC = md5( (K' xor opad) || md5( (K' xor ipad) || message ) )
     */
    fun hmacMd5Hex(input: String, key: String): String =
        hmacMd5(input.encodeToByteArray(), key.encodeToByteArray()).toHexLE()

    /** HMAC-MD5 内部实现，结构完全对照上面已验证的 hmacSha1 */
    private fun hmacMd5(message: ByteArray, key: ByteArray): IntArray {
        var k = key
        if (k.size > 64) k = md5WordsToBytes(md5Digest(k))
        val block = ByteArray(64)
        k.copyInto(block)
        val inner = ByteArray(64 + message.size)
        val outer = ByteArray(64 + 16)
        for (i in 0 until 64) {
            inner[i] = (block[i].toInt() xor 0x36).toByte()
            outer[i] = (block[i].toInt() xor 0x5c).toByte()
        }
        message.copyInto(inner, 64)
        md5WordsToBytes(md5Digest(inner)).copyInto(outer, 64)
        return md5Digest(outer)
    }

    /** md5 的字节版入口（现有 md5 接收字节返回 IntArray，这里起别名便于阅读） */
    private fun md5Digest(message: ByteArray): IntArray = md5(message)

    /**
     * IntArray → ByteArray，**小端**逐字展开。
     * 依据：md5Hex() 用 toHexLE()（小端）才能和 Python 对齐，
     * 说明 md5() 内部字是小端序。hmacSha1 用的 wordsToBytes 是大端，
     * 那是 sha1 的字序差异，不能直接复用给 md5。
     */
    private fun md5WordsToBytes(words: IntArray): ByteArray {
        val out = ByteArray(words.size * 4)
        for (i in words.indices) {
            val v = words[i]
            out[i * 4] = (v and 0xFF).toByte()
            out[i * 4 + 1] = ((v ushr 8) and 0xFF).toByte()
            out[i * 4 + 2] = ((v ushr 16) and 0xFF).toByte()
            out[i * 4 + 3] = ((v ushr 24) and 0xFF).toByte()
        }
        return out
    }

    // ---------- MD5（RFC 1321） ----------

    private val MD5_K = intArrayOf(
        0xd76aa478.toInt(), 0xe8c7b756.toInt(), 0x242070db.toInt(), 0xc1bdceee.toInt(),
        0xf57c0faf.toInt(), 0x4787c62a.toInt(), 0xa8304613.toInt(), 0xfd469501.toInt(),
        0x698098d8.toInt(), 0x8b44f7af.toInt(), 0xffff5bb1.toInt(), 0x895cd7be.toInt(),
        0x6b901122.toInt(), 0xfd987193.toInt(), 0xa679438e.toInt(), 0x49b40821.toInt(),
        0xf61e2562.toInt(), 0xc040b340.toInt(), 0x265e5a51.toInt(), 0xe9b6c7aa.toInt(),
        0xd62f105d.toInt(), 0x02441453.toInt(), 0xd8a1e681.toInt(), 0xe7d3fbc8.toInt(),
        0x21e1cde6.toInt(), 0xc33707d6.toInt(), 0xf4d50d87.toInt(), 0x455a14ed.toInt(),
        0xa9e3e905.toInt(), 0xfcefa3f8.toInt(), 0x676f02d9.toInt(), 0x8d2a4c8a.toInt(),
        0xfffa3942.toInt(), 0x8771f681.toInt(), 0x6d9d6122.toInt(), 0xfde5380c.toInt(),
        0xa4beea44.toInt(), 0x4bdecfa9.toInt(), 0xf6bb4b60.toInt(), 0xbebfbc70.toInt(),
        0x289b7ec6.toInt(), 0xeaa127fa.toInt(), 0xd4ef3085.toInt(), 0x04881d05.toInt(),
        0xd9d4d039.toInt(), 0xe6db99e5.toInt(), 0x1fa27cf8.toInt(), 0xc4ac5665.toInt(),
        0xf4292244.toInt(), 0x432aff97.toInt(), 0xab9423a7.toInt(), 0xfc93a039.toInt(),
        0x655b59c3.toInt(), 0x8f0ccc92.toInt(), 0xffeff47d.toInt(), 0x85845dd1.toInt(),
        0x6fa87e4f.toInt(), 0xfe2ce6e0.toInt(), 0xa3014314.toInt(), 0x4e0811a1.toInt(),
        0xf7537e82.toInt(), 0xbd3af235.toInt(), 0x2ad7d2bb.toInt(), 0xeb86d391.toInt(),
    )
    private val MD5_S = intArrayOf(
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    )

    private fun md5(message: ByteArray): IntArray {
        var a0 = 0x67452301.toInt(); var b0 = 0xefcdab89.toInt()
        var c0 = 0x98badcfe.toInt(); var d0 = 0x10325476.toInt()

        val bitLen = message.size.toLong() * 8
        val padded = message.size + 1 + ((55 - message.size) mod64 64) + 8
        val buf = ByteArray(padded)
        message.copyInto(buf)
        buf[message.size] = 0x80.toByte()
        // 64 位长度 = 小端（RFC 1321）：低位字节在低地址（buf[padded-8] 起写）
        for (i in 0 until 8) buf[padded - 8 + i] = ((bitLen ushr (8 * i)) and 0xFF).toByte()

        var i = 0
        while (i < padded) {
            val m = IntArray(16)
            for (j in 0 until 16) {
                val o = i + j * 4
                m[j] = (buf[o].toInt() and 0xFF) or
                    ((buf[o + 1].toInt() and 0xFF) shl 8) or
                    ((buf[o + 2].toInt() and 0xFF) shl 16) or
                    ((buf[o + 3].toInt() and 0xFF) shl 24)
            }
            var a = a0; var b = b0; var c = c0; var d = d0
            for (r in 0 until 64) {
                val (f, g) = when (r / 16) {
                    0 -> ((b and c) or (b.inv() and d)) to r
                    1 -> ((d and b) or (d.inv() and c)) to ((5 * r + 1) % 16)
                    2 -> (b xor c xor d) to ((3 * r + 5) % 16)
                    else -> (c xor (b or d.inv())) to ((7 * r) % 16)
                }
                val tmp = d
                d = c; c = b
                b = b + rotl(a + f + MD5_K[r] + m[g], MD5_S[r])
                a = tmp
            }
            a0 += a; b0 += b; c0 += c; d0 += d
            i += 64
        }
        return intArrayOf(a0, b0, c0, d0)
    }

    // ---------- SHA-1（RFC 3174） ----------

    private fun sha1(message: ByteArray): IntArray {
        val h = intArrayOf(0x67452301.toInt(), 0xefcdab89.toInt(), 0x98badcfe.toInt(), 0x10325476.toInt(), 0xc3d2e1f0.toInt())
        val bitLen = message.size.toLong() * 8
        val total = message.size + 1 + ((55 - message.size) mod64 64) + 8
        val buf = ByteArray(total)
        message.copyInto(buf)
        buf[message.size] = 0x80.toByte()
        // 64 位长度 = 大端（RFC 3174）：高位字节在低地址（buf[total-8] 起写）
        for (i in 0 until 8) buf[total - 8 + i] = ((bitLen ushr (8 * (7 - i))) and 0xFF).toByte()

        var i = 0
        while (i < total) {
            val w = IntArray(80)
            for (j in 0 until 16) {
                val o = i + j * 4
                w[j] = ((buf[o].toInt() and 0xFF) shl 24) or
                    ((buf[o + 1].toInt() and 0xFF) shl 16) or
                    ((buf[o + 2].toInt() and 0xFF) shl 8) or
                    (buf[o + 3].toInt() and 0xFF)
            }
            for (j in 16 until 80) w[j] = rotl(w[j - 3] xor w[j - 8] xor w[j - 14] xor w[j - 16], 1)

            var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]; var e = h[4]
            for (r in 0 until 80) {
                val f: Int; val k: Int
                when (r / 20) {
                    0 -> { f = (b and c) or (b.inv() and d); k = 0x5a827999.toInt() }
                    1 -> { f = b xor c xor d; k = 0x6ed9eba1.toInt() }
                    2 -> { f = (b and c) or (b and d) or (c and d); k = 0x8f1bbcdc.toInt() }
                    else -> { f = b xor c xor d; k = 0xca62c1d6.toInt() }
                }
                val temp = rotl(a, 5) + f + k + w[r] + e
                e = d; d = c; c = rotl(b, 30); b = a
                a = temp
            }
            h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e
            i += 64
        }
        return h
    }

    // ---------- HMAC-SHA1（RFC 2104） ----------

    private fun hmacSha1(message: ByteArray, key: ByteArray): IntArray {
        var k = key
        if (k.size > 64) k = wordsToBytes(sha1(k))
        val block = ByteArray(64)
        k.copyInto(block)
        val inner = ByteArray(64 + message.size)
        val outer = ByteArray(64 + 20)
        for (i in 0 until 64) {
            inner[i] = (block[i].toInt() xor 0x36).toByte()
            outer[i] = (block[i].toInt() xor 0x5c).toByte()
        }
        message.copyInto(inner, 64)
        wordsToBytes(sha1(inner)).copyInto(outer, 64)
        return sha1(outer)
    }

    // ---------- 位与字节工具 ----------

    private fun rotl(x: Int, n: Int): Int = (x shl n) or (x ushr (32 - n))

    private infix fun Int.mod64(m: Int): Int {
        val r = this % m
        return if (r < 0) r + m else r
    }

    private fun wordsToBytes(words: IntArray): ByteArray {
        val out = ByteArray(words.size * 4)
        for (i in words.indices) {
            val v = words[i]
            out[i * 4] = ((v ushr 24) and 0xFF).toByte()
            out[i * 4 + 1] = ((v ushr 16) and 0xFF).toByte()
            out[i * 4 + 2] = ((v ushr 8) and 0xFF).toByte()
            out[i * 4 + 3] = (v and 0xFF).toByte()
        }
        return out
    }

    private fun IntArray.toHex(): String {
        val sb = StringBuilder(size * 8)
        val HEX = "0123456789abcdef"
        for (wv in this) {
            val word = wv
            for (shift in 24 downTo 0 step 8) {
                sb.append(HEX[((word ushr (shift + 4)) and 0x0F)])
                sb.append(HEX[(word ushr shift) and 0x0F])
            }
        }
        return sb.toString()
    }
}
