// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Desktop-style compose entrypoint: `application { Window(...) { ... } }`
// with Compose Desktop's signatures drives the real androidx.compose.ui
// engine in a native window when a windowing backend is available. The window
// shows a few frames and then exits the application, so the example ends by
// itself; headless the window never opens.
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    var opened = false
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "klio compose",
            state = rememberWindowState(width = 320.dp, height = 240.dp),
        ) {
            MaterialTheme {
                Column {
                    var count by remember { mutableStateOf(0) }
                    Text("count=$count")
                    Button(onClick = { count += 1 }) { Text("Add") }
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
    println("application done")
}
