// Adapted from compose-multiplatform-core desktopMain (v1.12.0),
// androidx/compose/foundation/text/TextFieldKeyInput.desktop.kt: the typed
// event is the platform event a klio window sends behind a key event, where
// the desktop's is the AWT event, and the printable check reads Unicode's
// blocks from the ranges where the JDK's differ from "any block".
/*
 * Copyright 2021 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package androidx.compose.foundation.text

import androidx.compose.foundation.InternalFoundationApi
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KlioNativeKeyEvent
import androidx.compose.ui.input.key.klioNativeEventOrNull

/**
 * Not a control character, not the undefined character, in a Unicode block and
 * not in the Specials block (U+FFF0..U+FFFF). The Basic Multilingual Plane's
 * one range outside every block is U+2FE0..U+2FEF.
 */
private fun Char.isPrintable(): Boolean {
    val inBlock = code !in 0x2FE0..0x2FEF
    val special = code in 0xFFF0..0xFFFF
    return !isISOControl() &&
        this != KlioNativeKeyEvent.CHAR_UNDEFINED &&
        inBlock &&
        !special
}

// This API was never supposed to be public, but currently there are some external usages of it,
// so it cannot be removed from the public right now.
// However, starting with 1.9 it's marked as NOT a public-stable API with compatibility guarantees.
@OptIn(InternalComposeUiApi::class)
@InternalFoundationApi
actual val KeyEvent.isTypedEvent: Boolean
    get() = klioNativeEventOrNull?.id == KlioNativeKeyEvent.KEY_TYPED &&
        klioNativeEventOrNull?.keyChar?.isPrintable() == true
