// A native window's input, as the Skia shim's window backends report it
// (src/compose_ui/window_events.h), sent into its scene the way Compose
// Desktop's ComposeSceneMediator sends AWT's: mouse events with the buttons
// and modifiers they carry, key presses and releases, each typed character as
// a key event of its own with the platform event behind it, and the input
// method's composing and committed text to the focused field.

package androidx.compose.ui.window

import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.InternalKeyEvent
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.KlioNativeKeyEvent
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerKeyboardModifiers
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.platform.WindowInfoImpl
import androidx.compose.ui.scene.ComposeScene

/** The event types a window's poll reports. */
internal const val WINDOW_EVENT_NONE = 0
internal const val WINDOW_EVENT_CLOSE = 2
internal const val WINDOW_EVENT_RESIZE = 5
internal const val WINDOW_EVENT_POINTER = 10
internal const val WINDOW_EVENT_KEY = 11
internal const val WINDOW_EVENT_TEXT = 12
internal const val WINDOW_EVENT_FOCUS = 13
internal const val WINDOW_EVENT_MOVE = 14
internal const val WINDOW_EVENT_PLACEMENT = 15
internal const val WINDOW_EVENT_MENU = 16
internal const val WINDOW_EVENT_IME = 19
internal const val WINDOW_EVENT_A11Y = 20
internal const val WINDOW_EVENT_DND = 23

/** How many values a window event carries. */
internal const val WINDOW_EVENT_VALUES = 12

private const val MOD_SHIFT = 1
private const val MOD_CTRL = 2
private const val MOD_ALT = 4
private const val MOD_META = 8
private const val MOD_ALT_GRAPH = 16
private const val MOD_CAPS_LOCK = 32
private const val MOD_NUM_LOCK = 64
private const val MOD_SCROLL_LOCK = 128

private const val KEY_LOCATION_STANDARD = 1

/** The modifiers a window event carries, as the desktop reports AWT's. */
private fun keyboardModifiers(mods: Int) = PointerKeyboardModifiers(
    isCtrlPressed = mods and MOD_CTRL != 0,
    isMetaPressed = mods and MOD_META != 0,
    isAltPressed = mods and MOD_ALT != 0,
    isShiftPressed = mods and MOD_SHIFT != 0,
    isAltGraphPressed = mods and MOD_ALT_GRAPH != 0,
    isCapsLockOn = mods and MOD_CAPS_LOCK != 0,
    isScrollLockOn = mods and MOD_SCROLL_LOCK != 0,
    isNumLockOn = mods and MOD_NUM_LOCK != 0,
)

private fun pointerButtons(held: Int) = PointerButtons(
    isPrimaryPressed = held and 1 != 0,
    isSecondaryPressed = held and 2 != 0,
    isTertiaryPressed = held and 4 != 0,
    isBackPressed = held and 8 != 0,
    isForwardPressed = held and 16 != 0,
)

/**
 * One window's input: the events its poll reports, sent into [scene]. Typed
 * characters carry the modifiers of the key press that typed them. A key
 * event goes to the window's [onPreviewKeyEvent] first, then the content,
 * then [onKeyEvent], as a desktop window's does; a disabled window takes no
 * input and one that is not focusable no keys.
 */
@OptIn(InternalComposeUiApi::class)
internal class KlioWindowInput(
    private val scene: ComposeScene,
    private val windowInfo: WindowInfoImpl,
    private val handle: Long,
    private val textInput: KlioWindowTextInput?,
    private val accessibility: KlioWindowAccessibility?,
    private val dragAndDrop: KlioWindowDragAndDrop?,
) {
    private var keyModifiers = PointerKeyboardModifiers()

    var enabled: Boolean = true
    var focusable: Boolean = true
    var onPreviewKeyEvent: (KeyEvent) -> Boolean = { false }
    var onKeyEvent: (KeyEvent) -> Boolean = { false }
    /** The window's menu bar's shortcuts: runs the one a key press is. */
    var menuShortcut: (KeyEvent) -> Boolean = { false }
    /** The window gained or lost the focus. */
    var onFocusChanged: () -> Unit = {}
    /** The window moved with the mouse: its frame's new top-left on the screen. */
    var onMoved: (x: Int, y: Int) -> Unit = { _, _ -> }

    /** Where the pointer last was in the window's content. */
    private var pointerX = 0
    private var pointerY = 0

    /**
     * A move of the window with the mouse: the window frame's top-left and the
     * pointer on the screen (the frame's position plus the pointer's in the
     * content) when it started. Null while the window is not moving.
     */
    private var move: IntArray? = null

    /**
     * Moves the window together with the mouse until the press is released, as
     * Compose Desktop moves a window by hand: each drag moves it by as much as
     * the pointer moved on the screen since the move started.
     */
    fun startMovingTogetherWithMouse() {
        val frame = __composeui_winPosition(handle)
        val x = (frame shr 32).toInt()
        val y = frame.toInt()
        move = intArrayOf(x, y, x + pointerX, y + pointerY)
    }

    private fun moveWithMouse(eventType: PointerEventType, held: Int) {
        val m = move ?: return
        if (eventType == PointerEventType.Release || held and 1 == 0) {
            move = null
            return
        }
        if (eventType != PointerEventType.Move) return
        val frame = __composeui_winPosition(handle)
        val screenX = (frame shr 32).toInt() + pointerX
        val screenY = frame.toInt() + pointerY
        val x = m[0] + screenX - m[2]
        val y = m[1] + screenY - m[3]
        __composeui_winSetPosition(handle, x, y)
        onMoved(x, y)
    }

    /** Sends a pointer, key, text, input method or focus event; the others are the window loop's. */
    fun send(type: Int, v: DoubleArray) {
        when (type) {
            WINDOW_EVENT_POINTER -> if (enabled) sendPointer(v)
            WINDOW_EVENT_KEY -> if (enabled && focusable) sendKey(v)
            WINDOW_EVENT_TEXT -> if (enabled && focusable) sendText(v)
            WINDOW_EVENT_IME -> if (enabled && focusable) sendInputMethod(v)
            WINDOW_EVENT_A11Y -> if (enabled) sendAccessibility(v)
            WINDOW_EVENT_DND -> if (enabled) {
                val kind = v[0].toInt()
                // Only a drag's enter, move and drop carry its data.
                val payload = if (kind == 1 || kind == 2 || kind == 4) __composeui_winEventText(handle) else ""
                dragAndDrop?.onEvent(kind, v[1].toFloat(), v[2].toFloat(), v[3].toInt(), payload)
            }
            WINDOW_EVENT_FOCUS -> {
                windowInfo.isWindowFocused = v[0] != 0.0
                onFocusChanged()
            }
        }
    }

    private fun sendKeyEvent(event: KeyEvent): Boolean =
        onPreviewKeyEvent(event) || scene.sendKeyEvent(event) || onKeyEvent(event)

    private fun sendPointer(v: DoubleArray) {
        val eventType = when (v[0].toInt()) {
            1 -> PointerEventType.Press
            2 -> PointerEventType.Release
            3 -> PointerEventType.Move
            4 -> PointerEventType.Enter
            5 -> PointerEventType.Exit
            6 -> PointerEventType.Scroll
            else -> return
        }
        val button = v[5].toInt()
        pointerX = v[1].toInt()
        pointerY = v[2].toInt()
        moveWithMouse(eventType, v[6].toInt())
        scene.sendPointerEvent(
            eventType = eventType,
            position = Offset(v[1].toFloat(), v[2].toFloat()),
            scrollDelta = Offset(v[3].toFloat(), v[4].toFloat()),
            type = PointerType.Mouse,
            buttons = pointerButtons(v[6].toInt()),
            keyboardModifiers = keyboardModifiers(v[7].toInt()),
            button = if (button > 0) PointerButton(button - 1) else null,
        )
    }

    private fun sendKey(v: DoubleArray) {
        val pressed = v[0].toInt() == 1
        val keyChar = v[3].toInt().toChar()
        val modifiers = keyboardModifiers(v[7].toInt())
        keyModifiers = modifiers
        val event =
            KeyEvent(
                nativeKeyEvent = InternalKeyEvent(
                    key = Key(nativeKeyCode = v[1].toInt(), nativeKeyLocation = v[2].toInt()),
                    type = if (pressed) KeyEventType.KeyDown else KeyEventType.KeyUp,
                    codePoint = keyChar.code,
                    modifiers = modifiers,
                    nativeEvent = KlioNativeKeyEvent(
                        if (pressed) KlioNativeKeyEvent.KEY_PRESSED else KlioNativeKeyEvent.KEY_RELEASED,
                        keyChar,
                    ),
                )
            )
        val consumed = sendKeyEvent(event)
        // A menu bar's accelerators see the press the content leaves.
        if (pressed && (!consumed || menuShortcutsAfterConsumedKeys)) menuShortcut(event)
    }

    // The input method's event: the text it commits, then the text it composes.
    private fun sendInputMethod(v: DoubleArray) {
        val input = textInput ?: return
        val text = __composeui_winEventText(handle)
        val committed = v[0].toInt().coerceIn(0, text.length)
        input.onInputMethodEvent(text.substring(0, committed), text.substring(committed))
    }

    // What an assistive client asks: to start reading the window (action 0),
    // or an action of a node.
    private fun sendAccessibility(v: DoubleArray) {
        val a11y = accessibility ?: return
        val action = v[1].toInt()
        if (action == 0) {
            a11y.onActivated()
            return
        }
        val text = if (action == A11yAction.SET_TEXT) __composeui_winEventText(handle) else ""
        a11y.perform(v[0].toInt(), action, text)
    }

    // Each typed character is a key event of its own, as AWT types them: of no
    // key, of no known type, one UTF-16 unit at a time.
    private fun sendText(v: DoubleArray) {
        val n = v[0].toInt()
        for (i in 1..n) {
            val cp = v[i].toInt()
            if (cp >= 0x10000) {
                val offset = cp - 0x10000
                sendTyped(((offset shr 10) + 0xD800).toChar())
                sendTyped(((offset and 0x3FF) + 0xDC00).toChar())
            } else {
                sendTyped(cp.toChar())
            }
        }
    }

    private fun sendTyped(ch: Char) {
        sendKeyEvent(
            KeyEvent(
                nativeKeyEvent = InternalKeyEvent(
                    key = Key(nativeKeyCode = 0, nativeKeyLocation = KEY_LOCATION_STANDARD),
                    type = KeyEventType.Unknown,
                    codePoint = ch.code,
                    modifiers = keyModifiers,
                    nativeEvent = KlioNativeKeyEvent(KlioNativeKeyEvent.KEY_TYPED, ch),
                )
            )
        )
    }
}
