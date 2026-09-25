// Compose runtime: hot reload and live literals.
//
// simulateHotReload disposes every running composition's content and composes
// it again. While hot reload mode is on, an exception a recomposition throws is
// recorded (getCurrentCompositionErrors) instead of ending the recomposer, and
// the next hot reload clears it and composes the content again. The runtime
// logs the captured error on standard error, so standard output carries only
// this program's lines. A live literal is snapshot state kept by key.
@file:OptIn(InternalComposeApi::class)

import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.InternalComposeApi
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.clearCompositionErrors
import androidx.compose.runtime.disableHotReloadMode
import androidx.compose.runtime.getCurrentCompositionErrors
import androidx.compose.runtime.internal.liveLiteral
import androidx.compose.runtime.internal.updateLiveLiteralValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.simulateHotReload
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

/** A composition with no node tree: this demo only observes composition. */
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

/** Publish pending state writes and dispatch frames until the recomposer is idle. */
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
fun Greeting(name: MutableState<String>) {
    println("Greeting ${name.value}")
    check(name.value != "boom") { "cannot greet ${name.value}" }
}

fun errors(): String =
    getCurrentCompositionErrors().joinToString(prefix = "[", postfix = "]") { (cause, recoverable) ->
        "${cause::class.simpleName}: ${cause.message} (recoverable=$recoverable)"
    }

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        val name = mutableStateOf("klio")
        composition.setContent { Greeting(name) }

        println("-- hot reload")
        simulateHotReload(Unit)
        settle(recomposer, clock)
        println("errors: ${errors()}")

        println("-- a recomposition throws")
        name.value = "boom"
        settle(recomposer, clock)
        println("errors: ${errors()}")
        println("recomposer state: ${recomposer.currentState.value}")

        println("-- hot reload after the fix")
        name.value = "fixed"
        simulateHotReload(Unit)
        settle(recomposer, clock)
        println("errors: ${errors()}")

        println("-- a recorded error is cleared")
        name.value = "boom"
        settle(recomposer, clock)
        println("errors: ${errors().length > 2}")
        clearCompositionErrors()
        println("errors: ${errors()}")
        disableHotReloadMode()

        println("-- live literals")
        val size = liveLiteral("Greeting.size", 12)
        println("size ${size.value}")
        updateLiveLiteralValue("Greeting.size", 16)
        println("size ${size.value}")
        println("same state: ${liveLiteral("Greeting.size", 0) === size}")

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
