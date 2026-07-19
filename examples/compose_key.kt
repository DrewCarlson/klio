// Compose runtime: key{} ties a subtree's identity — and therefore its
// remembered state — to the key rather than the slot position. When the key
// changes, the subtree is a new identity, so `remember` re-initializes; without
// the key, the same slot is reused and the remembered value persists. The key
// change is driven by a state write that recomposes the content.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.key
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

/** A composition with no node tree: this demo only observes key identity. */
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

/** The remembered value records which user was current when it first ran. */
@Composable
fun Profile(userId: Int, keyed: Boolean) {
    if (keyed) {
        key(userId) {
            val loadedFor = remember { userId }
            println("  user=$userId remembered=$loadedFor")
        }
    } else {
        val loadedFor = remember { userId }
        println("  user=$userId remembered=$loadedFor")
    }
}

suspend fun run(recomposer: Recomposer, clock: BroadcastFrameClock, keyed: Boolean) {
    val composition = Composition(UnitApplier(), recomposer)
    val user = mutableStateOf(1)
    println(if (keyed) "with key:" else "without key:")
    composition.setContent { Profile(user.value, keyed) }
    println("  -- switch to user 2 --")
    user.value = 2
    settle(recomposer, clock)
    composition.dispose()
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        run(recomposer, clock, true)
        run(recomposer, clock, false)

        recomposer.close()
        runner.cancelAndJoin()
    }
}
