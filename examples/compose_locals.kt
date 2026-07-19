// Compose runtime: CompositionLocal — a value provided to a subtree, with
// nested overrides and a default outside any provider.
//
// Driven through the real androidx.compose.runtime API: a `Recomposer` runs on
// the calling coroutine (`runRecomposeAndApplyChanges`) and the composition is
// materialized once through `setContent`.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin

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

val LocalName = compositionLocalOf { "default" }

@Composable
fun Greeting() {
    println("hello, ${LocalName.current}")
}

@Composable
fun App() {
    Greeting()
    CompositionLocalProvider(LocalName provides "Alice") {
        Greeting()
        CompositionLocalProvider(LocalName provides "Bob") {
            Greeting()
        }
        Greeting()
    }
    Greeting()
}

fun main() {
    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()

        val composition = Composition(UnitApplier(), recomposer)
        composition.setContent { App() }

        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
}
