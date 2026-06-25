// Compose runtime capstone: a small counter "app". State + remember + a
// @Composable tree, re-rendered each frame after a state write drives a
// recomposition. The rendered UI is printed as text.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember

class CounterState {
    val count: MutableState<Int> = mutableStateOf(0)
    fun increment() {
        count.value = count.value + 1
    }
}

@Composable
fun Label(text: String) {
    println("  label: $text")
}

@Composable
fun CounterScreen(state: CounterState) {
    val title = remember { "Counter" }
    println("frame {")
    Label(title)
    Label("count = ${state.count.value}")
    println("}")
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val state = CounterState()

    composition.setContent { CounterScreen(state) }

    var clicks = 0
    while (clicks < 3) {
        state.increment()
        recomposer.recompose()
        clicks = clicks + 1
    }

    composition.dispose()
}
