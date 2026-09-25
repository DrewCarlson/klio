/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.input.key

import androidx.compose.ui.InternalComposeUiApi

/**
 * The platform event behind a key event a klio window sends, as an AWT key
 * event is behind a desktop one: its [id] tells a pressed, released or typed
 * key apart, and [keyChar] is the character, as AWT's are.
 */
@InternalComposeUiApi
class KlioNativeKeyEvent(val id: Int, val keyChar: Char) {
    override fun toString(): String = "KlioNativeKeyEvent(id=$id, keyChar=${keyChar.code})"

    companion object {
        const val KEY_TYPED = 400
        const val KEY_PRESSED = 401
        const val KEY_RELEASED = 402

        /** The character of a key that types none. */
        const val CHAR_UNDEFINED: Char = '￿'
    }
}

/** The platform event behind this key event, when a klio window sent it. */
@InternalComposeUiApi
val KeyEvent.klioNativeEventOrNull: KlioNativeKeyEvent?
    get() = internal.nativeEvent as? KlioNativeKeyEvent
