// Compose runtime: SideEffect runs after each composition that ran it;
// DisposableEffect runs setup once and onDispose when the composition disposes.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.DisposableEffect

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
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val state = mutableStateOf(0)

    composition.setContent { Widget(state) }
    state.value = 1
    recomposer.recompose()
    composition.dispose()

    println("log: ${log.toString().trim()}")
}
