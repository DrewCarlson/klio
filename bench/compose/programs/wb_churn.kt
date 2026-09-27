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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import kotlinx.coroutines.delay
import kotlin.time.TimeSource

// A second window opened and closed 150 times, then 3 seconds of idle:
// whatever a window leaves behind when it closes accumulates.
fun main() {
    val start = TimeSource.Monotonic.markNow()
    application {
        var second by remember { mutableStateOf(false) }
        Window(onCloseRequest = ::exitApplication, title = "churn", state = rememberWindowState(width = 400.dp, height = 300.dp)) {
            LaunchedEffect(Unit) {
                withFrameNanos { }
                println("first_frame_ms=${start.elapsedNow().inWholeMilliseconds}")
                for (cycle in 1..150) {
                    second = true
                    repeat(4) { withFrameNanos { } }
                    second = false
                    repeat(4) { withFrameNanos { } }
                    if (cycle % 50 == 0) println("cycle $cycle at_ms=${start.elapsedNow().inWholeMilliseconds}")
                }
                delay(3000)
                println("churn_done at_ms=${start.elapsedNow().inWholeMilliseconds}")
                exitApplication()
            }
            BasicText("main window", Modifier.padding(16.dp))
        }
        if (second) {
            Window(onCloseRequest = { second = false }, title = "second", state = rememberWindowState(width = 300.dp, height = 200.dp)) {
                Column(Modifier.padding(8.dp)) {
                    for (i in 0 until 10) BasicText("row $i of the second window")
                }
            }
        }
    }
}
