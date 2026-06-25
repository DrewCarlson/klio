// Compose runtime: observable state with mutableStateOf — reads, writes,
// `by` delegation, destructuring, and the structural-equality policy.
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

fun main() {
    val count = mutableStateOf(0)
    println("count = ${count.value}")
    count.value = 5
    println("count = ${count.value}")

    var name by mutableStateOf("world")
    println("hello, $name")
    name = "compose"
    println("hello, $name")

    val (value, setValue) = mutableStateOf(41)
    println("value = $value")
    setValue(42)

    // Structural equality: assigning an equal value is a no-op.
    val items = mutableStateOf(listOf(1, 2, 3))
    items.value = listOf(1, 2, 3)
    println("items = ${items.value}")
}
