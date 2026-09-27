import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import kotlin.time.TimeSource

// 45 seconds of a list scrolling through 5000 rows and back, with a
// changing header: steady allocation, for a memory trajectory.
fun main() {
    val start = TimeSource.Monotonic.markNow()
    application {
        Window(onCloseRequest = ::exitApplication, title = "long", state = rememberWindowState(width = 500.dp, height = 700.dp)) {
            var frames by remember { mutableIntStateOf(0) }
            val state = rememberLazyListState()
            LaunchedEffect(Unit) {
                withFrameNanos { }
                println("first_frame_ms=${start.elapsedNow().inWholeMilliseconds}")
                val run = TimeSource.Monotonic.markNow()
                var dir = 1f
                var next = 5
                while (run.elapsedNow().inWholeMilliseconds < 45_000) {
                    withFrameNanos { frames++ }
                    if (state.dispatchRawDelta(30f * dir) == 0f) dir = -dir
                    if (run.elapsedNow().inWholeSeconds >= next) {
                        println("t=${next}s frames=$frames")
                        next += 5
                    }
                }
                println("frames=$frames fps=${frames * 1000 / run.elapsedNow().inWholeMilliseconds}")
                exitApplication()
            }
            Column {
                BasicText("frame $frames", Modifier.padding(8.dp))
                LazyColumn(Modifier.fillMaxSize(), state = state) {
                    items(5000) { i ->
                        Row(Modifier.fillMaxWidth().height(40.dp).padding(4.dp)) {
                            Box(Modifier.size(32.dp).background(Color(0xFF000000.toInt() or ((i * 40503) and 0xFFFFFF))))
                            BasicText("Item number $i", Modifier.padding(start = 8.dp))
                        }
                    }
                }
            }
        }
    }
}
