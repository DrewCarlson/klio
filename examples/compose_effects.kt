// Compose runtime: SideEffect runs after each composition that ran it;
// DisposableEffect runs setup once and onDispose when the composition disposes.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

/** A composition with no node tree: this demo only observes effects. */
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

val log = StringBuilder()

@Composable
fun Widget(state: MutableState<Int>) {
    SideEffect { log.append("effect(${state.value}) ") }
    DisposableEffect(Unit) {
        log.append("setup ")
        onDispose { log.append("teardown ") }
    }
    println("Widget value=${state.value}")
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val state = mutableStateOf(0)

        composition.setContent { Widget(state) }
        state.value = 1
        settle(recomposer, clock)
        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()

        println("log: ${log.toString().trim()}")
    }
}
