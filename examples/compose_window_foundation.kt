// corpus: skia (the expected output is the one printed when the Skia shim renders)
// The same desktop entrypoint as compose_window.kt with NO material3 in the
// program at all: `application { Window(...) }` over foundation only —
// Column/Box, `Modifier.background`/`padding`/`clickable`, and BasicText —
// so the window path is covered without a material dependency. The window
// shows a few frames and then exits the application; headless it never
// opens and the example prints `window opened=false`.
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    var opened = false
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "klio foundation",
            state = rememberWindowState(width = 320.dp, height = 240.dp),
        ) {
            var count by remember { mutableStateOf(0) }
            Column(Modifier.padding(8.dp)) {
                BasicText("count=$count")
                Box(
                    Modifier.background(Color(0xFF1B5E20))
                        .clickable { count += 1 }
                        .padding(8.dp)
                ) {
                    BasicText("Add", style = TextStyle(color = Color.White))
                }
            }
            LaunchedEffect(Unit) {
                opened = true
                repeat(3) { withFrameNanos { } }
                exitApplication()
            }
        }
    }
    println("window opened=" + opened)
    println("foundation window done")
}
