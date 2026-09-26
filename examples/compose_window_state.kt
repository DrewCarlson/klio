// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Compose Desktop's window API: a Window follows its WindowState both ways
// (the position the program sets moves the native window, and the window
// reports where it is), a DialogWindow opens and closes with the state that
// composes it, and the window's onPreviewKeyEvent sees keys before the
// content and its onKeyEvent the ones the content leaves. The keys come from
// compose_window_state.input, scripted into the window ($KLIO_WIN_INPUT).
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberDialogState
import kotlinx.coroutines.flow.first

fun main() {
    val state = WindowState(size = DpSize(320.dp, 240.dp), position = WindowPosition(100.dp, 120.dp))
    var opened = false
    var keys by mutableStateOf(0)
    application(exitProcessOnExit = false) {
        var showDialog by remember { mutableStateOf(false) }
        Window(
            onCloseRequest = ::exitApplication,
            state = state,
            title = "window state",
            onPreviewKeyEvent = {
                val name = if (it.key == Key.B) "B" else "A"
                println("preview $name ${it.type}")
                // B stops here; A goes on to the content and then onKeyEvent.
                it.key == Key.B
            },
            onKeyEvent = {
                println("window hears ${if (it.key == Key.B) "B" else "A"} ${it.type}")
                keys++
                false
            },
        ) {
            Box {}
            LaunchedEffect(Unit) {
                opened = true
                withFrameNanos { }
                println("shown: size=${state.size} position=${state.position} placement=${state.placement}")
                state.position = WindowPosition(140.dp, 160.dp)
                repeat(3) { withFrameNanos { } }
                println("moved: position=${state.position}")
                showDialog = true
                repeat(3) { withFrameNanos { } }
                showDialog = false
                // A's press and release reach onKeyEvent.
                snapshotFlow { keys }.first { it >= 2 }
                exitApplication()
            }
        }
        if (showDialog) {
            val dialogState = rememberDialogState(size = DpSize(200.dp, 120.dp))
            DialogWindow(onCloseRequest = { showDialog = false }, state = dialogState, title = "dialog") {
                LaunchedEffect(Unit) {
                    println("dialog opened, size=${dialogState.size}")
                }
            }
        }
    }
    println("window opened=$opened")
    if (opened) println("final position=${state.position} placement=${state.placement}")
}
