// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Compose Desktop's mouse gestures in a native window: Modifier.onClick with a
// PointerMatcher tells the buttons apart and takes double clicks, and
// Modifier.onDrag reports a drag's start, deltas and end. The mouse comes
// from compose_window_pointer.input, scripted into the window
// ($KLIO_WIN_INPUT).
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.PointerMatcher
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.onDrag
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.onClick
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

@OptIn(ExperimentalFoundationApi::class)
fun main() {
    var opened = false
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "pointer",
            state = rememberWindowState(width = 300.dp, height = 300.dp),
        ) {
            Column {
                // y 0..100: clicks by button.
                Box(
                    Modifier.size(100.dp).border(1.dp, Color.Black)
                        .onClick { println("primary click") }
                        .onClick(matcher = PointerMatcher.mouse(PointerButton.Secondary)) {
                            println("secondary click")
                        }
                        .onClick(matcher = PointerMatcher.mouse(PointerButton.Tertiary)) {
                            println("tertiary click")
                        }
                )
                // y 100..200: double clicks.
                Box(
                    Modifier.size(100.dp).border(1.dp, Color.Black)
                        .onClick(onDoubleClick = { println("double click") }) { println("single click") }
                )
                // y 200..: drags.
                Box(
                    Modifier.size(60.dp).border(1.dp, Color.Black)
                        .onDrag(
                            onDragStart = { println("drag start at $it") },
                            onDragEnd = { println("drag end") },
                        ) { println("drag by $it") }
                )
            }
            // Sixty frames, a second, then the application ends.
            LaunchedEffect(Unit) {
                opened = true
                repeat(60) { withFrameNanos { } }
                exitApplication()
            }
        }
    }
    println("window opened=$opened")
}
