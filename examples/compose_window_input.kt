// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window's own input: the mouse, the keyboard and typed text a native
// window reports reach its content as Compose Desktop delivers AWT's. Here
// they come from compose_window_input.input, which the example runner hands
// the window as scripted input ($KLIO_WIN_INPUT): a click into a single-line
// text field, typing, a Backspace, Tab to the next focusable, Enter and Space
// on it, and a click on it. The window's onPreviewKeyEvent sees each key
// before the content and takes Escape; its onKeyEvent hears the keys the
// content leaves.
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    val field = TextFieldState()
    var clicks = 0
    var opened = false
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "input",
            state = rememberWindowState(width = 300.dp, height = 240.dp),
            onPreviewKeyEvent = {
                if (it.key == Key.Escape && it.type == KeyEventType.KeyDown) {
                    println("window takes Escape")
                    true
                } else {
                    false
                }
            },
            onKeyEvent = {
                if (it.type == KeyEventType.KeyDown) {
                    val name = when (it.key) {
                        Key.F1 -> "F1"
                        Key.Escape -> "Escape"
                        else -> "another key"
                    }
                    println("window hears $name")
                }
                false
            },
        ) {
            // The window runs thirty frames, then the application ends.
            LaunchedEffect(Unit) {
                opened = true
                repeat(30) { withFrameNanos { } }
                exitApplication()
            }
            Column {
                BasicTextField(
                    field,
                    Modifier.size(200.dp, 40.dp).border(1.dp, Color.Black)
                        .onFocusChanged { if (it.isFocused) println("field focused") },
                    lineLimits = TextFieldLineLimits.SingleLine,
                )
                Box(
                    Modifier.size(100.dp, 40.dp).border(1.dp, Color.Black)
                        .onFocusChanged { if (it.isFocused) println("button focused") }
                        .clickable { clicks++; println("button clicked ($clicks)") }
                )
            }
        }
    }
    println("window opened=$opened")
    if (opened) {
        println("text=${field.text}")
        println("clicks=$clicks")
    }
}
