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

// ui's desktopMain KeyShortcut.desktop.kt (v1.12.0): its equals compares
// classes with ::class where the desktop's reads javaClass, and the Swing
// KeyStroke conversion goes; a window's menu bar matches a key event against
// the shortcut itself (matches).
package androidx.compose.ui.input.key

// TODO(https://youtrack.jetbrains.com/issue/CMP-5337): support arbitrary shortcuts
/**
 * Represents a key combination which should be pressed on a keyboard to trigger some action.
 */
class KeyShortcut(
    /**
     * Key that should be pressed to trigger an action
     */
    internal val key: Key,

    /**
     * true if Ctrl modifier key should be pressed to trigger an action
     */
    internal val ctrl: Boolean = false,

    /**
     * true if Meta modifier key should be pressed to trigger an action
     * (it is Command on macOs)
     */
    internal val meta: Boolean = false,

    /**
     * true if Alt modifier key should be pressed to trigger an action
     */
    internal val alt: Boolean = false,

    /**
     * true if Shift modifier key should be pressed to trigger an action
     */
    internal val shift: Boolean = false,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other == null || this::class != other::class) return false

        other as KeyShortcut

        if (key != other.key) return false
        if (ctrl != other.ctrl) return false
        if (meta != other.meta) return false
        if (alt != other.alt) return false
        if (shift != other.shift) return false

        return true
    }

    override fun hashCode(): Int {
        var result = key.hashCode()
        result = 31 * result + ctrl.hashCode()
        result = 31 * result + meta.hashCode()
        result = 31 * result + alt.hashCode()
        result = 31 * result + shift.hashCode()
        return result
    }

    override fun toString() = buildString {
        if (ctrl) append("Ctrl+")
        if (meta) append("Meta+")
        if (alt) append("Alt+")
        if (shift) append("Shift+")
        append(key)
    }
}

/**
 * Whether a key press is the shortcut's, as a Swing KeyStroke matches one: its
 * key, with exactly the shortcut's modifiers held.
 */
internal fun KeyShortcut.matches(event: KeyEvent): Boolean =
    event.type == KeyEventType.KeyDown &&
        event.key.nativeKeyCode == key.nativeKeyCode &&
        event.isCtrlPressed == ctrl &&
        event.isMetaPressed == meta &&
        event.isAltPressed == alt &&
        event.isShiftPressed == shift
