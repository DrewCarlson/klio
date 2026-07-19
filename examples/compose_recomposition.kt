// Compose runtime: a state write recomposes only the composable that read the
// state (and its ancestors). A sibling that did not read it is skipped.
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
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

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

var readerRuns = 0
var siblingRuns = 0
var frameTime = 0L

/** Publish pending state writes and dispatch frames until the recomposer is
 * idle, so a recomposition provoked by a write has completed on return. */
suspend fun settle(recomposer: Recomposer, clock: BroadcastFrameClock) {
    Snapshot.sendApplyNotifications()
    while (recomposer.hasPendingWork) {
        yield()
        frameTime += 16_666_666L
        clock.sendFrame(frameTime)
        yield()
    }
}

@Composable
fun Reader(state: MutableState<Int>) {
    readerRuns = readerRuns + 1
    println("Reader sees ${state.value}")
}

@Composable
fun Sibling() {
    siblingRuns = siblingRuns + 1
    println("Sibling")
}

@Composable
fun App(state: MutableState<Int>) {
    Reader(state)
    Sibling()
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val state = mutableStateOf(0)

        composition.setContent { App(state) }
        println("after compose: readerRuns=$readerRuns siblingRuns=$siblingRuns")

        state.value = 1
        Snapshot.sendApplyNotifications()
        println("hasPendingWork=${recomposer.hasPendingWork}")
        settle(recomposer, clock)
        println("after recompose: readerRuns=$readerRuns siblingRuns=$siblingRuns")

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
