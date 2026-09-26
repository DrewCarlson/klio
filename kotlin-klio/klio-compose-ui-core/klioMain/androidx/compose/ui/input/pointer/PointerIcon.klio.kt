package androidx.compose.ui.input.pointer

/**
 * The standard pointer icons, as the desktop's are AWT's cursors: each one a
 * system cursor a klio window shows while the pointer is over content that
 * asks for it ([kind] is the shim's KLIO_CURSOR_*).
 *
 * `PointerIcon.Companion` reads all four at class-init, so a text field cannot
 * compose at all without them (`BasicTextField` sets the text cursor on hover).
 */
internal class KlioPointerIcon(val name: String, val kind: Int) : PointerIcon {
    override fun toString(): String = "PointerIcon($name)"
}

internal actual val pointerIconDefault: PointerIcon = KlioPointerIcon("default", 0)
internal actual val pointerIconCrosshair: PointerIcon = KlioPointerIcon("crosshair", 1)
internal actual val pointerIconText: PointerIcon = KlioPointerIcon("text", 2)
internal actual val pointerIconHand: PointerIcon = KlioPointerIcon("hand", 3)
