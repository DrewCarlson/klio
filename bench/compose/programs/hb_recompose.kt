import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp
import kotlin.time.TimeSource

// 300 texts that all change every frame: recomposition, text layout and
// drawing of a screenful of changing numbers.
fun main() {
    val scene = KlioComposeScene(800, 600)
    val setup = TimeSource.Monotonic.markNow()
    scene.setContent {
        var tick by remember { mutableIntStateOf(0) }
        LaunchedEffect(Unit) {
            while (true) withFrameNanos { tick++ }
        }
        Column {
            for (r in 0 until 20) {
                Row {
                    for (c in 0 until 15) {
                        BasicText("${(tick * 7 + r * 15 + c) % 1000}", Modifier.width(50.dp))
                    }
                }
            }
        }
    }
    report("recompose", setup.elapsedNow().inWholeMicroseconds, scene)
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

