// Compose runtime: a @Composable tree composes in source order, and `remember`
// memoizes a value across recompositions of the same content.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.remember

var allocations = 0

fun freshId(): Int {
    allocations = allocations + 1
    return allocations
}

@Composable
fun Item(label: String) {
    val id = remember { freshId() }
    println("Item $label -> id $id")
}

@Composable
fun Screen() {
    println("Screen {")
    Item("first")
    Item("second")
    println("}")
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val content: @Composable () -> Unit = { Screen() }

    composition.setContent(content)
    println("allocations after first compose = $allocations")

    composition.setContent(content)
    println("allocations after second compose = $allocations")
}
