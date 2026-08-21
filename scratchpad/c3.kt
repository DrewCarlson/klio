import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking {
    val flo = flowOf(1,2,3)
    println(flo.filter { it % 2 == 0 }.toList())
}
