// StateFlow.collectAsState: mirror a kotlinx.coroutines MutableStateFlow into a
// compose State that a composable reads, driving recomposition on every value
// change. The collector runs in produceState's coroutine under the Recomposer;
// each StateFlow update resumes it, updates the State, and recomposes. Run inside
// runBlocking.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import kotlinx.coroutines.flow.MutableStateFlow
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

    val source = MutableStateFlow(0)
    composition.setContent {
        Mirror(source.collectAsState())
    }

    delay(20); source.value = 10
    delay(20); source.value = 20
    delay(20)

    recomposer.close()
    runner.cancelAndJoin()
    composition.dispose()
    println("done")
}
