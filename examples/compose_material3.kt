// Material 3 API surface + MaterialTheme composable theming, running through the
// real vendored androidx.compose.material3 pack over the compose runtime, ui,
// foundation, and graphics-shapes packs. Builds color schemes / typography /
// shapes, then reads them back through MaterialTheme's CompositionLocals inside a
// composition — including a nested MaterialTheme that overrides the theme for its
// subtree and restores it afterward.

import androidx.compose.runtime.Applier
import androidx.compose.runtime.BroadcastFrameClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.coroutines.cancelAndJoin
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.Typography
import androidx.compose.material3.Shapes
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape

/** A composition with no node tree: this demo only reads theme locals. */
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

@Composable
fun ThemedContent() {
    MaterialTheme(
        colorScheme = lightColorScheme(primary = Color.Blue, secondary = Color.Red),
        typography = Typography(),
        shapes = Shapes(small = RoundedCornerShape(4.dp)),
    ) {
        println("primary=${MaterialTheme.colorScheme.primary}")
        println("secondary=${MaterialTheme.colorScheme.secondary}")
        println("bodyLarge=${MaterialTheme.typography.bodyLarge.fontSize}")
        println("small shape set=${MaterialTheme.shapes.small != null}")

        // A nested theme overrides the subtree, then the outer theme is restored.
        MaterialTheme(colorScheme = darkColorScheme(primary = Color.Green)) {
            println("nested primary=${MaterialTheme.colorScheme.primary}")
        }
        println("restored primary=${MaterialTheme.colorScheme.primary}")
    }
}

fun main() {
    // The plain builders work outside a composition too.
    val scheme = lightColorScheme(primary = Color.Blue)
    val copied = scheme.copy(tertiary = Color.Yellow)
    println("scheme.primary=${scheme.primary}")
    println("copied.tertiary=${copied.tertiary}")
    println("copied.primary=${copied.primary}")

    val clock = BroadcastFrameClock()
    runBlocking(clock) {
        val recomposer = Recomposer(coroutineContext)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        yield()
        val composition = Composition(UnitApplier(), recomposer)
        composition.setContent { ThemedContent() }
        composition.dispose()
        recomposer.close()
        runner.cancelAndJoin()
    }
    println("done")
}
