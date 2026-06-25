// snapshotFlow + collectAsState: bridge compose's observable state to a
// kotlinx.coroutines Flow and back. snapshotFlow turns a state read into a cold
// Flow that re-emits whenever the state changes; collectAsState mirrors a Flow
// into a State a composable reads, driving recomposition. Run under a Recomposer
// inside runBlocking.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

@Composable
fun Mirror(value: State<Int>) {
    println("mirror = ${value.value}")
}

fun main() = runBlocking {
    val recomposer = Recomposer(coroutineContext)
    val composition = Composition(recomposer)
    val runner = launch { recomposer.runRecomposeAndApplyChanges() }

    val source = mutableStateOf(0)
    composition.setContent {
        val mirrored = snapshotFlow { source.value }.collectAsState(initial = -1)
        Mirror(mirrored)
    }

    delay(20); source.value = 10
    delay(20); source.value = 20
    delay(20)

    recomposer.close()
    runner.cancelAndJoin()
    composition.dispose()
    println("done")
}
