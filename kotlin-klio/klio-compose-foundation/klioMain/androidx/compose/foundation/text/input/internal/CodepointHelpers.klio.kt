/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text.input.internal

/** The number of `Char`s a code point occupies: 2 above the BMP, 1 otherwise. */
internal actual fun charCount(codePoint: Int): Int = if (codePoint >= 0x10000) 2 else 1

/**
 * The code point at [index], as `java.lang.Character.codePointAt` answers it: a
 * high surrogate followed by a low one is the supplementary code point they
 * encode, and any other char is its own value.
 */
internal actual fun CharSequence.codePointAt(index: Int): Int {
    val high = this[index]
    if (high.isHighSurrogate() && index + 1 < length) {
        val low = this[index + 1]
        if (low.isLowSurrogate()) return toCodePoint(high, low)
    }
    return high.code
}

/**
 * The code point before [index], as `java.lang.Character.codePointBefore`
 * answers it: a low surrogate preceded by a high one is the supplementary code
 * point they encode, and any other char is its own value.
 */
internal actual fun CharSequence.codePointBefore(index: Int): Int {
    val low = this[index - 1]
    if (low.isLowSurrogate() && index - 2 >= 0) {
        val high = this[index - 2]
        if (high.isHighSurrogate()) return toCodePoint(high, low)
    }
    return low.code
}

private fun toCodePoint(high: Char, low: Char): Int =
    ((high.code - 0xD800) shl 10) + (low.code - 0xDC00) + 0x10000
