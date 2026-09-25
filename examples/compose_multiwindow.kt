// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Multi-window compose application with recomposition-driven window
// parameters: two Windows compose side by side, the first window's TITLE
// follows counter state, the second window is GATED on state (leaving the
// composition closes it), and exitApplication ends the application. Headless
// the windows never open and the same state trace prints.
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
    var composed = false
    var opened = false
    application(exitProcessOnExit = false) {
        var clicks by remember { mutableStateOf(0) }
        var showSecond by remember { mutableStateOf(true) }
        composed = true
        // Frame by frame: retitle window 1 live, close window 2 live (leaving
        // the composition disposes its native window), then exit.
        LaunchedEffect(Unit) {
            withFrameNanos { }
            clicks = 7
            withFrameNanos { }
            showSecond = false
            withFrameNanos { }
            exitApplication()
        }

        Window(
            onCloseRequest = ::exitApplication,
            title = "main clicks=$clicks",
            state = rememberWindowState(width = 320.dp, height = 240.dp),
        ) {
            opened = true
            MaterialTheme {
                Column {
                    Text("clicks=$clicks")
                    Button(onClick = { clicks += 1 }) { Text("Add") }
                }
            }
        }
        if (showSecond) {
            Window(
                onCloseRequest = { showSecond = false },
                title = "second",
                state = rememberWindowState(width = 200.dp, height = 160.dp),
            ) {
                MaterialTheme { Text("second window") }
            }
        }
    }
    println("windows opened=" + opened)
    println("app composed=" + composed)
    println("multiwindow done")
}
