// Desktop-style compose entrypoint: `application { Window(...) { ... } }`
// drives the REAL androidx.compose.ui engine in a native window when a
// windowing backend is available, and reports headless cleanly otherwise —
// so this example prints deterministic output in both environments.
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    // maxFrames bounds the loop so the example prints deterministically in
    // CI; a real app omits it and runs until the window closes.
    val opened = application(maxFrames = 3) {
        Window(onCloseRequest = ::exitApplication, title = "klio compose", width = 320, height = 240) {
            MaterialTheme {
                Column {
                    var count by remember { mutableStateOf(0) }
                    Text("count=$count")
                    Button(onClick = { count += 1 }) { Text("Add") }
                }
            }
        }
    }
    println("window opened=" + opened)
    println("application done")
}
