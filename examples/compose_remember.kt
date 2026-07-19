// Compose runtime: a @Composable tree composes in source order, and `remember`
// memoizes a value across recompositions of the same content. A state write
// bumps a generation that flows to each Item as a parameter, forcing it to
// recompose; its remembered id survives, so no fresh ids are allocated.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

/** A composition with no node tree: this demo only observes remember. */
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

var allocations = 0
var frameTime = 0L

fun freshId(): Int {
    allocations = allocations + 1
    return allocations
}

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
fun Item(label: String, generation: Int) {
    val id = remember { freshId() }
    println("Item $label -> id $id")
}

@Composable
fun Screen(generation: Int) {
    println("Screen (gen=$generation) {")
    Item("first", generation)
    Item("second", generation)
    println("}")
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val generation = mutableStateOf(0)

        composition.setContent { Screen(generation.value) }
        println("allocations after first compose = $allocations")

        generation.value = 1
        settle(recomposer, clock)
        println("allocations after second compose = $allocations")

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
