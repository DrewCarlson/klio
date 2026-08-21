import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val flow = flowOf(1, 2, 3)
    println("toList      = " + flow.filter { it % 2 == 0 }.toList())
    println("count       = " + flow.filter { true }.count())
    println("fold        = " + flow.filter { true }.fold(0) { a, b -> a + b })
    println("map+toList  = " + flow.map { it * 2 }.toList())
}
