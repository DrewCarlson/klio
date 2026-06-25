// The compose frame clock, consumed straight from upstream
// (MonotonicFrameClock / BroadcastFrameClock / AwaiterQueue). A Recomposer driven
// inside runBlocking fans a frame to withFrameNanos awaiters each pass: a
// LaunchedEffect awaits frames and advances animation state, and each advance
// recomposes the content that reads it. coroutineContext[MonotonicFrameClock]
// resolves to the recomposer's clock.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

@Composable
fun Frames(tick: State<Int>) {
    println("render frame ${tick.value}")
}

fun main() = runBlocking {
    val recomposer = Recomposer(coroutineContext)
    val composition = Composition(recomposer)
    val runner = launch { recomposer.runRecomposeAndApplyChanges() }

    val tick = mutableStateOf(0)
    composition.setContent {
        Frames(tick)
        LaunchedEffect(Unit) {
            println("clock present: ${coroutineContext[MonotonicFrameClock] != null}")
            repeat(3) {
                withFrameNanos { /* frame boundary */ }
                tick.value = tick.value + 1
            }
        }
    }

    delay(50)
    recomposer.close()
    runner.cancelAndJoin()
    composition.dispose()
    println("done")
}
