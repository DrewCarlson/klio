// The compose frame clock, consumed straight from upstream
// (MonotonicFrameClock / BroadcastFrameClock / AwaiterQueue). A Recomposer driven
// inside runBlocking fans a frame to withFrameNanos awaiters each pass: a
// LaunchedEffect awaits frames and advances animation state, and each advance
// recomposes the content that reads it. coroutineContext[MonotonicFrameClock]
// resolves to the recomposer's clock.
//
// Driven through the real androidx.compose.runtime API: a `Recomposer` runs on
// the calling coroutine (`runRecomposeAndApplyChanges`) and frames are dispatched
// through a `BroadcastFrameClock` the recomposer fans out to its awaiters.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MonotonicFrameClock
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

/** A composition with no node tree: this demo only observes recomposition. */
class UnitApplier : Applier<Unit> {
    override val current: Unit = Unit
    override fun down(node: Unit) {}
    override fun up() {}
    override fun insertTopDown(index: Int, instance: Unit) {}
    override fun insertBottomUp(index: Int, instance: Unit) {}
    override fun remove(index: Int, count: Int) {}
    override fun move(from: Int, to: Int, count: Int) {}
    override fun clear() {}
}

var frameTime = 0L

/** Let effect coroutines run, publish their state writes, and dispatch frames
 * until the recomposer is idle. */
suspend fun settle(recomposer: Recomposer, clock: BroadcastFrameClock) {
    repeat(6) {
        yield()
        Snapshot.sendApplyNotifications()
        while (recomposer.hasPendingWork) {
            yield()
            frameTime += 16_666_666L
            clock.sendFrame(frameTime)
            yield()
            Snapshot.sendApplyNotifications()
        }
    }
}

@Composable
fun Frames(tick: State<Int>) {
    println("render frame ${tick.value}")
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
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
        settle(recomposer, clock)

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
    println("done")
}
