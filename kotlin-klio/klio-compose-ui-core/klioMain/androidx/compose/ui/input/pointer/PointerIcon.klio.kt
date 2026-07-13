/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.input.pointer

/**
 * klio actuals for the four standard pointer icons.
 *
 * `PointerIcon` is an opaque handle: the engine only ever compares icons and hands
 * the current one to the platform. klio's window layer does not set a system cursor
 * yet, so each icon is a distinct identity carrying the name the backend will use
 * once it does — distinct so `PointerIcon.Text != PointerIcon.Default` behaves as
 * the hover/text-field logic expects.
 *
 * `PointerIcon.Companion` reads all four at class-init, so a text field cannot
 * compose at all without them (`BasicTextField` sets the text cursor on hover).
 */
internal class KlioPointerIcon(val name: String) : PointerIcon {
    override fun toString(): String = "PointerIcon($name)"
}

internal actual val pointerIconDefault: PointerIcon = KlioPointerIcon("default")
internal actual val pointerIconCrosshair: PointerIcon = KlioPointerIcon("crosshair")
internal actual val pointerIconText: PointerIcon = KlioPointerIcon("text")
internal actual val pointerIconHand: PointerIcon = KlioPointerIcon("hand")
