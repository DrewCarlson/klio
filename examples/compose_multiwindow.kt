// Multi-window compose application with recomposition-driven window
// parameters: two Windows compose side by side, the first window's TITLE
// follows counter state, the second window is GATED on state (leaving the
// composition closes it), and exitApplication ends the loop. Headless the
// windows never open and the same state trace prints — deterministic output
// in both environments.
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
    var frames = 0
    val opened = application(maxFrames = 8) {
        var clicks by remember { mutableStateOf(0) }
        var showSecond by remember { mutableStateOf(true) }
        frames += 1
        // Each pass writes state the block reads, so recomposition chains:
        // pass 2 retitles window 1 live, pass 3 closes window 2 live
        // (leaving the composition disposes its native window), pass 4 exits.
        if (frames == 1) clicks = 7
        if (frames == 2) showSecond = false
        if (frames == 3) exitApplication()

        Window(onCloseRequest = ::exitApplication, title = "main clicks=$clicks", width = 320, height = 240) {
            MaterialTheme {
                Column {
                    Text("clicks=$clicks")
                    Button(onClick = { clicks += 1 }) { Text("Add") }
                }
            }
        }
        if (showSecond) {
            Window(onCloseRequest = { showSecond = false }, title = "second", width = 200, height = 160) {
                MaterialTheme { Text("second window") }
            }
        }
    }
    println("windows opened=" + opened)
    println("app composed=" + (frames >= 1))
    println("multiwindow done")
}
