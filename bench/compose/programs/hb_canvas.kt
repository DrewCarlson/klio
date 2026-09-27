import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.klio.KlioComposeScene
import kotlin.math.cos
import kotlin.math.sin
import kotlin.time.TimeSource

// 2000 circles drawn at positions that move every frame: the draw phase
// alone (no recomposition of the tree, one Canvas redrawn).
fun main() {
    val scene = KlioComposeScene(800, 600)
    val setup = TimeSource.Monotonic.markNow()
    scene.setContent {
        var nanos by remember { mutableLongStateOf(0L) }
        LaunchedEffect(Unit) {
            while (true) withFrameNanos { nanos = it }
        }
        Canvas(Modifier.fillMaxSize()) {
            val t = nanos / 1e9f
            for (i in 0 until 2000) {
                val a = i * 0.37f + t
                val r = 20f + (i % 50) * 5f
                drawCircle(
                    Color(0xFF000000.toInt() or ((i * 40503) and 0xFFFFFF)),
                    radius = 4f,
                    center = Offset(400f + r * cos(a), 300f + r * sin(a)),
                )
            }
        }
    }
    report("canvas", setup.elapsedNow().inWholeMicroseconds, scene)
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

