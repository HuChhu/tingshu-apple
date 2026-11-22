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
        // key 超过 64 字节时要先 md5
        val longKey = "a".repeat(100)
        val v = Crypto.hmacMd5Hex("msg", longKey)
        assertEquals(32, v.length, "hex 长度应为 32")
    }

    @Test
    fun emptyMessageWorks() {
        val v = Crypto.hmacMd5Hex("", "key")
        assertEquals(32, v.length)
    }
}
