// Compose runtime: key{} gives each list item an identity tied to its key rather
// than its position, so its remembered state follows the item across a reorder.
// Contrast the keyed and unkeyed runs: with key, the remembered creation order
// tracks the id; without, it tracks the slot position.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.remember
import androidx.compose.runtime.key

var creations = 0
fun nextCreation(): Int { creations = creations + 1; return creations }

@Composable
fun Row(id: Int) {
    val created = remember { nextCreation() }
    println("  id=$id created=$created")
}

@Composable
fun Rows(ids: List<Int>, keyed: Boolean) {
    for (id in ids) {
        if (keyed) key(id) { Row(id) } else Row(id)
    }
}

fun run(keyed: Boolean) {
    creations = 0
    val composition = Composition(Recomposer())
    var ids = listOf(1, 2, 3)
    val content: @Composable () -> Unit = { Rows(ids, keyed) }
    println(if (keyed) "with key:" else "without key:")
    composition.setContent(content)
    println("  -- reorder to [3, 1, 2] --")
    ids = listOf(3, 1, 2)
    composition.setContent(content)
}

fun main() {
    run(true)
    run(false)
}
