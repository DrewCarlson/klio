// The input a desktop scene takes, sent the way Compose Desktop's
// ImageComposeScene sends it: mouse buttons other than the primary one, drags,
// wheel scrolls and keys. A press and release report the button that changed
// and the buttons held, Modifier.onDrag reports a drag's start, deltas and
// end, a scroll reaches Modifier.onPointerEvent with its delta, and Tab moves
// the focus between two focusable boxes, whose key listener hears the keys
// sent to the focused one. The events are the ones Compose Desktop 1.12.0
// delivers. (A key prints by name here: its own text is the platform's, a
// glyph on macOS and a word elsewhere.)
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.onDrag
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class, InternalComposeUiApi::class)
fun main() {
    val scene = KlioComposeScene(200, 300)
    scene.setContent {
        Column {
            // y 0..100: presses and releases by button.
            var buttons = Modifier.size(100.dp)
            for (type in listOf(PointerEventType.Press, PointerEventType.Release)) {
                buttons = buttons.onPointerEvent(type) { event ->
                    val held = event.buttons
                    println(
                        "$type ${event.button} primary=${held.isPrimaryPressed} " +
                            "secondary=${held.isSecondaryPressed} tertiary=${held.isTertiaryPressed}"
                    )
                }
            }
            Box(buttons)
            // y 100..200: drags and scrolls.
            Box(
                Modifier.size(100.dp)
                    .onDrag(
                        onDragStart = { println("drag start at $it") },
                        onDragEnd = { println("drag end") },
                        onDragCancel = { println("drag cancel") },
                    ) { println("drag by $it") }
                    .onPointerEvent(PointerEventType.Scroll) { event ->
                        println("scroll ${event.changes.first().scrollDelta}")
                    }
            )
            // y 200..250 and 250..300: two focusable boxes.
            for (name in listOf("first", "second")) {
                Box(
                    Modifier.size(50.dp)
                        .onFocusChanged { if (it.isFocused) println("$name focused") }
                        .onKeyEvent {
                            val key = when (it.key) {
                                Key.Tab -> "Tab"
                                Key.A -> "A"
                                else -> "other"
                            }
                            println("$name hears $key ${it.type} shift=${it.isShiftPressed}")
                            false
                        }
                        .focusable()
                )
            }
        }
    }

    println("-- secondary button")
    scene.sendPointerEvent(PointerEventType.Press, Offset(20f, 20f), button = PointerButton.Secondary)
    scene.sendPointerEvent(PointerEventType.Release, Offset(20f, 20f), button = PointerButton.Secondary)
    scene.frame()
    println("-- tertiary button")
    scene.sendPointerEvent(PointerEventType.Press, Offset(20f, 20f), button = PointerButton.Tertiary)
    scene.sendPointerEvent(PointerEventType.Release, Offset(20f, 20f), button = PointerButton.Tertiary)
    scene.frame()
    println("-- primary button")
    scene.sendPointerEvent(PointerEventType.Press, Offset(20f, 20f), button = PointerButton.Primary)
    scene.sendPointerEvent(PointerEventType.Release, Offset(20f, 20f), button = PointerButton.Primary)
    scene.frame()

    println("-- drag")
    scene.sendPointerEvent(PointerEventType.Press, Offset(10f, 110f), button = PointerButton.Primary)
    scene.sendPointerEvent(PointerEventType.Move, Offset(30f, 120f))
    scene.sendPointerEvent(PointerEventType.Move, Offset(60f, 150f))
    scene.sendPointerEvent(PointerEventType.Release, Offset(60f, 150f), button = PointerButton.Primary)
    scene.frame()

    println("-- scroll")
    scene.sendPointerEvent(PointerEventType.Scroll, Offset(50f, 150f), scrollDelta = Offset(0f, 3f))
    scene.sendPointerEvent(PointerEventType.Scroll, Offset(50f, 150f), scrollDelta = Offset(-1f, 0f))
    scene.frame()

    println("-- tab, tab, a, shift+tab")
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyDown))
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyUp))
    scene.frame()
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyDown))
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyUp))
    scene.frame()
    scene.sendKeyEvent(KeyEvent(Key.A, KeyEventType.KeyDown, codePoint = 'a'.code))
    scene.sendKeyEvent(KeyEvent(Key.A, KeyEventType.KeyUp, codePoint = 'a'.code))
    scene.frame()
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyDown, isShiftPressed = true))
    scene.sendKeyEvent(KeyEvent(Key.Tab, KeyEventType.KeyUp, isShiftPressed = true))
    scene.frame()
    scene.dispose()
}
