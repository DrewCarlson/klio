import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking {
    val flow = flowOf(1, 2, 3)
    println("A " + flow.filter { it % 2 == 0 }.toList())
}
