import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking {
    val flow = 42
    println(flowOf(1,2,3).filter { it % 2 == 0 }.toList())
}
