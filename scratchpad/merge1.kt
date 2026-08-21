import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    println(listOf(flowOf(1), flowOf(2)).merge().toList())
    println(listOf(flowOf(1), flowOf(null), flowOf(2)).merge().toList())
}
