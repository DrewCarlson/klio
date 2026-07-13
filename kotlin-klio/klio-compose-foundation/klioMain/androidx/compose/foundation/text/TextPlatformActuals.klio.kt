/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.AnnotatedString

/**
 * klio actuals for the foundation.text expects whose desktop implementations live
 * in JVM-coupled files (java.awt clipboard / Swing context menus), which the pack
 * cannot carry.
 */

/** The undo manager coalesces edits by wall-clock gap. */
internal actual fun timeNowMillis(): Long = kotlin.time.Clock.System.now().toEpochMilliseconds()

/**
 * Append a Unicode code point. Kotlin's `StringBuilder` takes `Char`s, so a
 * supplementary code point (above the BMP) must be appended as its surrogate
 * pair — the same thing Java's `appendCodePoint` does.
 */
internal actual fun StringBuilder.appendCodePointX(codePoint: Int): StringBuilder {
    if (codePoint < 0x10000) {
        append(codePoint.toChar())
    } else {
        val v = codePoint - 0x10000
        append((0xD800 + (v shr 10)).toChar())
        append((0xDC00 + (v and 0x3FF)).toChar())
    }
    return this
}

/**
 * klio has no system clipboard binding yet, so nothing intercepts the paste/copy/cut
 * key events and the field keeps its own handling. Returns false: "not handled here".
 */
@Composable
internal actual inline fun rememberClipboardEventsHandler(
    crossinline onPaste: (AnnotatedString) -> Unit,
    crossinline onCopy: () -> AnnotatedString?,
    crossinline onCut: () -> AnnotatedString?,
    isEnabled: Boolean,
): Boolean = false
