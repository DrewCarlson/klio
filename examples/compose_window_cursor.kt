// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window shows the system cursor its content asks for, as a Compose
// Desktop window shows the AWT cursor: the text cursor over a text field,
// the hand over content with a hand pointer icon, and the arrow elsewhere.
// The moves come from compose_window_cursor.input, scripted into the window
// ($KLIO_WIN_INPUT), each followed by the cursor the platform reports.
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "cursor") {
            var text by remember { mutableStateOf("text") }
            Column {
                BasicTextField(text, { text = it }, Modifier.size(200.dp, 30.dp).background(Color.LightGray))
                Box(Modifier.size(200.dp, 30.dp).background(Color.Gray).pointerHoverIcon(PointerIcon.Hand))
                Box(Modifier.size(200.dp, 30.dp).pointerHoverIcon(PointerIcon.Crosshair))
                Box(Modifier.size(200.dp, 30.dp))
            }
        }
    }
    println("application ended")
}
