import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import kotlin.time.TimeSource

// An animating window for 10 seconds: an infinite rotation, 24 pulsing
// boxes and a frame counter; prints when its first frame came and the
// frames it produced.
fun main() {
    val start = TimeSource.Monotonic.markNow()
    application {
        Window(onCloseRequest = ::exitApplication, title = "anim", state = rememberWindowState(width = 800.dp, height = 600.dp)) {
            var frames by remember { mutableIntStateOf(0) }
            LaunchedEffect(Unit) {
                withFrameNanos { }
                println("first_frame_ms=${start.elapsedNow().inWholeMilliseconds}")
                val run = TimeSource.Monotonic.markNow()
                while (run.elapsedNow().inWholeMilliseconds < 10_000) withFrameNanos { frames++ }
                println("frames=$frames fps=${frames * 1000 / run.elapsedNow().inWholeMilliseconds}")
                exitApplication()
            }
            val transition = rememberInfiniteTransition()
            val angle by transition.animateFloat(0f, 360f, infiniteRepeatable(tween(2000, easing = LinearEasing)))
            val pulse by transition.animateFloat(0.2f, 1f, infiniteRepeatable(tween(700), RepeatMode.Reverse))
            Column(Modifier.padding(16.dp)) {
                BasicText("frame $frames")
                Box(Modifier.padding(24.dp).size(120.dp).rotate(angle).background(Color(0xFF3366CC)))
                for (r in 0 until 3) {
                    Row {
                        for (c in 0 until 8) {
                            Box(Modifier.padding(4.dp).size(40.dp).background(Color(0.2f, pulse * (c + 1) / 8f, 1f - pulse * (r + 1) / 3f)))
                        }
                    }
                }
            }
        }
    }
}
