// A skottie Logger is a Kotlin object the native animation builder calls back.
package org.jetbrains.skia.skottie

import org.jetbrains.skia.impl.NO_CALLBACKS
import org.jetbrains.skia.impl.NativePointer

internal actual fun Logger.doInit(ptr: NativePointer) {
    throw UnsupportedOperationException(NO_CALLBACKS)
}
