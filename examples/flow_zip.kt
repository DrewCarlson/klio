import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val a = flowOf(1, 2, 3)
    val b = flowOf("x", "y")
    println(a.zip(b) { n, s -> "$n$s" }.toList())
}
