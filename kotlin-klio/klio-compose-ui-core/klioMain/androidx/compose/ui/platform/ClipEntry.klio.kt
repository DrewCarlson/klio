/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The clipboard types of ui's ClipboardManager.kt, shaped as desktop's
// (PlatformClipboard.desktop.kt, PlatformClipboard.skiko.kt): a ClipEntry wraps
// the platform's own clip, which on the desktop is an AWT Transferable. klio's
// clipboard has no AWT behind it; its native clip is the AnnotatedString (or
// String) a copy put there.
package androidx.compose.ui.platform

import androidx.compose.ui.ExperimentalComposeUiApi

@Suppress("DEPRECATION")
actual typealias NativeClipboard = Any

actual class ClipMetadata private constructor()

actual class ClipEntry
@ExperimentalComposeUiApi
constructor(
    @property:ExperimentalComposeUiApi
    val nativeClipEntry: Any
) {
    actual val clipMetadata: ClipMetadata
        get() = TODO("ClipMetadata is not implemented. Consider using nativeClipboard")
}
