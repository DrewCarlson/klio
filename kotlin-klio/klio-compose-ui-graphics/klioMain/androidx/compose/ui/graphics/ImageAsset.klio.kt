/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

// The native target copies with memcpy; a little-endian read of the same bytes.
internal actual fun ByteArray.putBytesInto(array: IntArray, offset: Int, length: Int) {
    var b = 0
    for (i in offset until offset + length) {
        array[i] = (this[b].toInt() and 0xFF) or
            ((this[b + 1].toInt() and 0xFF) shl 8) or
            ((this[b + 2].toInt() and 0xFF) shl 16) or
            ((this[b + 3].toInt() and 0xFF) shl 24)
        b += 4
    }
}
