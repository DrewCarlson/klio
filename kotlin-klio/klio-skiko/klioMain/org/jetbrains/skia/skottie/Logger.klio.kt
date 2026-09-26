// A skottie Logger is a Kotlin object the native animation builder calls back.
package org.jetbrains.skia.skottie

import org.jetbrains.skia.impl.NativePointer
import org.jetbrains.skia.impl.interopScope
import org.jetbrains.skia.impl.withStringReferenceNullableResult
import org.jetbrains.skia.impl.withStringReferenceResult

/** The logger's log, which the animation builder calls with each message. */
internal actual fun Logger.doInit(ptr: NativePointer) {
    interopScope {
        Logger_nInit(ptr, virtual {
            val message = withStringReferenceResult { Logger_nGetLogMessage(ptr) }
            val json = withStringReferenceNullableResult { Logger_nGetLogJson(ptr) }
            // skottie's Logger::Level: kWarning, kError.
            val level = if (Logger_nGetLogLevel(ptr) == 0) LogLevel.WARNING else LogLevel.ERROR
            log(level, message, json)
        })
    }
}
