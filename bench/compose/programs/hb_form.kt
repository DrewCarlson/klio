import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp
import kotlin.time.TimeSource

// A settings form of 40 rows (label, text field, toggle): the first
// composition of a typical screen, then idle frames with nothing to do.
fun main() {
    val scene = KlioComposeScene(800, 600)
    val setup = TimeSource.Monotonic.markNow()
    scene.setContent {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            for (i in 0 until 40) {
                var text by remember { mutableStateOf("value $i") }
                var on by remember { mutableStateOf(i % 2 == 0) }
                Row(Modifier.fillMaxWidth().padding(4.dp)) {
                    BasicText("Setting $i", Modifier.width(120.dp))
                    BasicTextField(text, { text = it }, Modifier.width(300.dp).border(1.dp, Color.Gray).padding(2.dp))
                    Box(Modifier.padding(start = 8.dp).size(20.dp).background(if (on) Color.Green else Color.LightGray).clickable { on = !on })
                }
            }
        }
    }
    report("form", setup.elapsedNow().inWholeMicroseconds, scene, warm = 10, frames = 100)
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

