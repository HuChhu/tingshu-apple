package com.local.audiobook.core

import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970

/** iOS 平台时钟：毫秒。commonMain 无 System.currentTimeMillis，按契约注入。 */
object PlatformClock {
    fun nowMs(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()
}
