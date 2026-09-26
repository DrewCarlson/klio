// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A WindowDraggableArea moves its window with the mouse, as a Compose Desktop
// window's does: from a press on the area, each drag moves the window by as
// much as the pointer moved, and the window's state follows it. A press
// outside the area moves nothing. The presses and drags come from
// compose_window_draggable.input, scripted into the window ($KLIO_WIN_INPUT).
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.window.WindowDraggableArea
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    application(exitProcessOnExit = false) {
        val state = rememberWindowState(position = WindowPosition(200.dp, 150.dp))
        Window(onCloseRequest = ::exitApplication, state = state, title = "draggable") {
            Column {
                WindowDraggableArea {
                    Box(Modifier.fillMaxWidth().height(40.dp).background(Color.DarkGray))
                }
                Box(Modifier.fillMaxWidth().height(100.dp))
            }
            LaunchedEffect(Unit) {
                val start = state.position
                snapshotFlow { state.position }.collect { position ->
                    if (position != start) {
                        val dx = position.x - start.x
                        val dy = position.y - start.y
                        println("moved by $dx, $dy")
                    }
                }
            }
        }
    }
    println("application ended")
}
