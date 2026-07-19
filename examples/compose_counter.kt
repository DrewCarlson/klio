// Compose runtime capstone: a small counter "app". State + remember + a
// @Composable tree, re-rendered each frame after a state write drives a
// recomposition. The rendered UI is printed as text.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

/** A composition that renders as printed text, not into a node tree. */
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

class CounterState {
    val count: MutableState<Int> = mutableStateOf(0)
    fun increment() {
        count.value = count.value + 1
    }
}

@Composable
fun Label(text: String) {
    println("  label: $text")
}

@Composable
fun CounterScreen(state: CounterState) {
    val title = remember { "Counter" }
    println("frame {")
    Label(title)
    Label("count = ${state.count.value}")
    println("}")
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val state = CounterState()

        composition.setContent { CounterScreen(state) }

        var clicks = 0
        while (clicks < 3) {
            state.increment()
            settle(recomposer, clock)
            clicks = clicks + 1
        }

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
