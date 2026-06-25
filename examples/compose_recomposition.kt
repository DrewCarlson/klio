// Compose runtime: a state write recomposes only the composable that read the
// state (and its ancestors). A sibling that did not read it is skipped.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf

var readerRuns = 0
var siblingRuns = 0

@Composable
fun Reader(state: MutableState<Int>) {
    readerRuns = readerRuns + 1
    println("Reader sees ${state.value}")
}

@Composable
fun Sibling() {
    siblingRuns = siblingRuns + 1
    println("Sibling")
}

@Composable
fun App(state: MutableState<Int>) {
    Reader(state)
    Sibling()
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val state = mutableStateOf(0)

    composition.setContent { App(state) }
    println("after compose: readerRuns=$readerRuns siblingRuns=$siblingRuns")

    state.value = 1
    println("hasInvalidations=${composition.hasInvalidations}")
    recomposer.recompose()
    println("after recompose: readerRuns=$readerRuns siblingRuns=$siblingRuns")
}
