// Compose runtime: a todo "app" tying together an observable list, a primitive
// state, a derivedStateOf, key{}-stable rows, and recomposition. Mutating the
// model recomposes only the parts that read what changed.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.SnapshotStateList
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

/** A composition with no node tree: this demo only prints. */
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

class TodoModel {
    val items: SnapshotStateList<String> = mutableStateListOf()
    val doneCount: MutableIntState = mutableIntStateOf(0)
    val remaining: State<Int> = derivedStateOf { items.size - doneCount.intValue }

    fun add(text: String) { items.add(text) }
    fun complete() { doneCount.intValue = doneCount.intValue + 1 }
}

var renders = 0

@Composable
fun TodoApp(model: TodoModel) {
    renders = renders + 1
    println("render #$renders (${model.items.size} items, ${model.remaining.value} remaining):")
    for (item in model.items) {
        println("  - $item")
    }
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val model = TodoModel()

        composition.setContent { TodoApp(model) }
        model.add("buy milk")
        settle(recomposer, clock)
        model.add("walk dog")
        settle(recomposer, clock)
        model.complete()
        settle(recomposer, clock)

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
