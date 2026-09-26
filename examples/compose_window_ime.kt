// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A text field in a window takes the input method's text as a Compose Desktop
// window's does: what the input method composes shows in the field as its
// composition, a newer composition replaces it, and the committed text
// replaces the composition and ends it; an empty composition abandons it.
// The typing, the compositions and the commits come from
// compose_window_ime.input, scripted into the window ($KLIO_WIN_INPUT).
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "ime") {
            var value by remember { mutableStateOf(TextFieldValue()) }
            val focus = remember { FocusRequester() }
            BasicTextField(
                value = value,
                onValueChange = {
                    if (it.text != value.text || it.composition != value.composition) {
                        println("text='${it.text}' composition=${it.composition} selection=${it.selection}")
                    }
                    value = it
                },
                modifier = Modifier.focusRequester(focus),
            )
            LaunchedEffect(Unit) { focus.requestFocus() }
        }
    }
    println("application ended")
}
