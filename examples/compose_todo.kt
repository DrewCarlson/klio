// Compose runtime: a todo "app" tying together an observable list, a primitive
// state, a derivedStateOf, key{}-stable rows, and recomposition. Mutating the
// model recomposes only the parts that read what changed.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.SnapshotStateList
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.derivedStateOf

class TodoModel {
    val items: SnapshotStateList<String> = mutableStateListOf()
    val doneCount: MutableIntState = mutableIntStateOf(0)
    val remaining: State<Int> = derivedStateOf { items.size - doneCount.intValue }

    fun add(text: String) { items.add(text) }
    fun complete() { doneCount.intValue = doneCount.intValue + 1 }
}

var renders = 0

@Composable
fun TodoApp(model: TodoModel) {
    renders = renders + 1
    println("render #$renders (${model.items.size} items, ${model.remaining.value} remaining):")
    for (item in model.items) {
        println("  - $item")
    }
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val model = TodoModel()

    composition.setContent { TodoApp(model) }
    model.add("buy milk")
    recomposer.recompose()
    model.add("walk dog")
    recomposer.recompose()
    model.complete()
    recomposer.recompose()

    composition.dispose()
}
