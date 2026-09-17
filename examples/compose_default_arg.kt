// A @Composable MEMBER with a default argument. The pass threads `$composer`
// and `$changed` by name so the trailing lambda still binds the callee's last
// function-typed parameter across the omitted default, and dispatch accepts a
// composable lambda instance as that binding. The default itself is computed
// once for the life of the group: the restart re-invokes with the RESOLVED
// value rather than the absent-argument marker, so an invalidation does not
// mint a second instance.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.RecomposeScope
import androidx.compose.runtime.currentRecomposeScope
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

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

suspend fun settle(recomposer: Recomposer, clock: BroadcastFrameClock) {
    Snapshot.sendApplyNotifications()
    while (recomposer.hasPendingWork) {
        yield()
        frameTime += 16_666_666L
        clock.sendFrame(frameTime)
        yield()
    }
}

class Screen {
    private val seen = mutableSetOf<Any>()
    var scope: RecomposeScope? = null

    @Composable
    private fun WithDefault(
        defaultValue: Any = Any(),
        block: @Composable (scope: RecomposeScope, defaultValue: Any) -> Unit,
    ) {
        block(currentRecomposeScope, defaultValue)
    }

    @Composable
    fun Content() {
        WithDefault { parentScope, defaultValue ->
            scope = parentScope
            seen += defaultValue
        }
    }

    fun distinctDefaults(): Int = seen.size
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()
        val composition = Composition(UnitApplier(), recomposer)
        val screen = Screen()

        composition.setContent { screen.Content() }
        println("distinct defaults after compose = " + screen.distinctDefaults())

        screen.scope?.invalidate()
        settle(recomposer, clock)
        println("distinct defaults after recompose = " + screen.distinctDefaults())

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
