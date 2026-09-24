/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// foundation's clipboard helpers (ClipboardUtils.kt). The desktop actuals read
// an AWT Transferable's string and AnnotatedString flavors; a klio ClipEntry's
// native clip is the AnnotatedString or String that was copied, so the same
// answers come from that.
@file:OptIn(ExperimentalComposeUiApi::class)

package androidx.compose.foundation.internal

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.text.AnnotatedString

internal actual suspend fun ClipEntry.readText(): String? =
    when (val clip = nativeClipEntry) {
        is AnnotatedString -> clip.text
        is String -> clip
        else -> null
    }

internal actual suspend fun ClipEntry.readAnnotatedString(): AnnotatedString? =
    when (val clip = nativeClipEntry) {
        is AnnotatedString -> clip
        is String -> AnnotatedString(clip)
        else -> null
    }

internal actual fun AnnotatedString?.toClipEntry(): ClipEntry? {
    if (this == null) return null
    return ClipEntry(this)
}

internal actual fun ClipEntry?.hasText(): Boolean {
    if (this == null) return false
    val clip = nativeClipEntry
    return clip is AnnotatedString || clip is String
}

internal actual fun Clipboard.isReadSupported(): Boolean = true

internal actual fun Clipboard.isWriteSupported(): Boolean = true
