package com.local.audiobook.core

import com.local.audiobook.data.ximalaya.engine.Crypto
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Crypto.hmacMd5Hex 测试。
 * 参考值来自 Python hmac/hashlib，确保纯 Kotlin 实现与标准一致。
 */
class CryptoHmacMd5Test {

    @Test
    fun simpleKeyMessage() {
        // Python: hmac.new(b"key", b"message", hashlib.md5).hexdigest()
        assertEquals("4e4748e62b463521f6775fbf921234b5", Crypto.hmacMd5Hex("message", "key"))
    }

    @Test
    fun qtfmRealSignature() {
        // 真实用例：蜻蜓 FM 音频签名（本次逆向出的密钥）
        val key = "7l8CZ)SgZgM_bkrw"
        val msg = "/audiostream/redirect/403408/26955208?access_token=&device_id=MOBILESITE&qingting_id=&t=1795389341310"
        // Python: hmac.new(b"7l8CZ)SgZgM_bkrw", msg, hashlib.md5).hexdigest()
        assertEquals("a502f15047e2a09b45330077328cdfb2", Crypto.hmacMd5Hex(msg, key))
    }

    @Test
    fun longKeyIsHashed() {
        // key 超过 64 字节时要先 md5。
        // P0（审计）：旧断言只比长度，而 hmacMd5 的 key>64 分支用 md5WordsToBytes 再做了一次
        // 小端→字节转换，等于把摘要字节序又倒了一遍，输出和标准对不上却仍是 32 个 hex 字符。
        // Python: hmac.new(b"a"*100, b"msg", hashlib.md5).hexdigest()
        val longKey = "a".repeat(100)
        assertEquals("2d6e3ac2454f97c38840a5942ca0dc99", Crypto.hmacMd5Hex("msg", longKey))
    }

    @Test
    fun keyExactly64BytesIsNotHashed() {
        // 边界：K' = key 长度 > 64 ? md5(key) : key —— 64 不 hash
        // Python: hmac.new(b"k"*64, b"x", hashlib.md5).hexdigest()
        assertEquals("f38420ee2e6c7cd5d9977bffba49d984", Crypto.hmacMd5Hex("x", "k".repeat(64)))
    }

    @Test
    fun key65BytesIsHashed() {
        // 边界外侧：65 > 64，必须 hash
        // Python: hmac.new(b"k"*65, b"y", hashlib.md5).hexdigest()
        assertEquals("866596955c35c9eaac5d9922b479062c", Crypto.hmacMd5Hex("y", "k".repeat(65)))
    }

    @Test
    fun utf8MessageIsEncodedAsUtf8() {
        // encodeToByteArray() 在 JVM/iOS 都是 UTF-8；这条钉死，防止以后有人换成平台默认编码
        // Python: hmac.new("密钥".encode(), "中文测试×Unicode".encode(), hashlib.md5).hexdigest()
        assertEquals("59cf6e324a69e70f253498d6dad0c4c9", Crypto.hmacMd5Hex("中文测试×Unicode", "密钥"))
    }

    @Test
    fun md5PaddingBoundaries() {
        // 55/56/63/64 字节是 MD5 padding 的四个转折点（补 1 位后跨不跨块）
        // Python: hashlib.md5(b"a"*n).hexdigest()
        assertEquals("ef1772b6dff9a122358552954ad0df65", Crypto.md5Hex("a".repeat(55)))
        assertEquals("3b0c8ac703f828b04c6c197006d17218", Crypto.md5Hex("a".repeat(56)))
        assertEquals("b06521f39153d618550606be297466d5", Crypto.md5Hex("a".repeat(63)))
        assertEquals("014842d480b571495a4a0363793f7367", Crypto.md5Hex("a".repeat(64)))
        assertEquals("5f61c0ccad4cac44c75ff505e1f1e537", Crypto.md5Hex("a".repeat(120)))
    }

    @Test
    fun asciiMessageVector() {
        // RFC 2202 风格的常规向量，跟 key>64 分支无关，防止改 key 分支时连带改坏主路径
        assertEquals(
            "80070713463e7749b90c2dc24911e275",
            Crypto.hmacMd5Hex("The quick brown fox jumps over the lazy dog", "key"),
        )
    }

    @Test
    fun emptyMessageWorks() {
        val v = Crypto.hmacMd5Hex("", "key")
        assertEquals(32, v.length)
    }
}
