// snapshotFlow + collectAsState: bridge compose's observable state to a
// kotlinx.coroutines Flow and back. snapshotFlow turns a state read into a cold
// Flow that re-emits whenever the state changes; collectAsState mirrors a Flow
// into a State a composable reads, driving recomposition. Run under a Recomposer
// inside runBlocking.
//
// Driven through the real androidx.compose.runtime API: a `Recomposer` runs on
// the calling coroutine (`runRecomposeAndApplyChanges`), a state write is
// published with `Snapshot.sendApplyNotifications`, and a frame is dispatched
// through a `BroadcastFrameClock` to apply the recomposition.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshotFlow
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
 * until the recomposer is idle, so a recomposition provoked by a flow emission
 * has completed on return. */
suspend fun settle(recomposer: Recomposer, clock: BroadcastFrameClock) {
    repeat(4) {
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
fun Mirror(value: State<Int>) {
    println("mirror = ${value.value}")
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val source = mutableStateOf(0)

        composition.setContent {
            val mirrored = snapshotFlow { source.value }.collectAsState(initial = -1)
            Mirror(mirrored)
        }
        settle(recomposer, clock)

        source.value = 10
        settle(recomposer, clock)

        source.value = 20
        settle(recomposer, clock)

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
    println("done")
}
