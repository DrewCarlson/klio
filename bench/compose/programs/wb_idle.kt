import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import kotlinx.coroutines.delay
import kotlin.time.TimeSource

// A window with nothing to do for 10 seconds after its first frame.
fun main() {
    val start = TimeSource.Monotonic.markNow()
    application {
        Window(onCloseRequest = ::exitApplication, title = "idle", state = rememberWindowState(width = 800.dp, height = 600.dp)) {
            LaunchedEffect(Unit) {
                withFrameNanos { }
                println("first_frame_ms=${start.elapsedNow().inWholeMilliseconds}")
                delay(10_000)
                println("idle_done")
                exitApplication()
            }
            Column(Modifier.padding(16.dp)) {
                for (i in 0 until 20) BasicText("A line of static text, number $i")
            }
        }
    }
}
