import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp
import kotlin.time.TimeSource

// A 5000-row LazyColumn scrolled 23 px every frame: item composition,
// layout and text as rows scroll in and out.
fun main() {
    val scene = KlioComposeScene(400, 600)
    val setup = TimeSource.Monotonic.markNow()
    scene.setContent {
        val state = rememberLazyListState()
        LaunchedEffect(Unit) {
            while (true) {
                withFrameNanos { }
                state.dispatchRawDelta(23f)
            }
        }
        LazyColumn(Modifier.fillMaxSize(), state = state) {
            items(5000) { i ->
                Row(Modifier.fillMaxWidth().height(40.dp).padding(4.dp)) {
                    Box(Modifier.size(32.dp).background(Color(0xFF000000.toInt() or ((i * 40503) and 0xFFFFFF))))
                    BasicText("Item number $i", Modifier.padding(start = 8.dp))
                }
            }
        }
    }
    report("list", setup.elapsedNow().inWholeMicroseconds, scene)
}

fun report(name: String, setupUs: Long, scene: KlioComposeScene, warm: Int = 60, frames: Int = 300) {
    repeat(warm) { scene.frame() }
    val times = LongArray(frames)
    val all = TimeSource.Monotonic.markNow()
    for (i in 0 until frames) {
        val m = TimeSource.Monotonic.markNow()
        scene.frame()
        times[i] = m.elapsedNow().inWholeMicroseconds
    }
    val total = all.elapsedNow().inWholeMicroseconds
    times.sort()
    fun ms(us: Long) = (us / 10).toDouble() / 100
    println("$name setContent_ms=${ms(setupUs)} frames=$frames mean_ms=${ms(total / frames)} p50_ms=${ms(times[frames / 2])} p95_ms=${ms(times[frames * 95 / 100])} max_ms=${ms(times[frames - 1])}")
}

