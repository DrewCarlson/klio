import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    val nested: Flow<Flow<Int>> = flowOf(flowOf(1, 2), flowOf(3))
    println("plain flow = " + nested.klioProbeFlatten().toList())
    println("alias flow = " + nested.klioProbeFlattenAlias().toList())
    println("upstream   = " + nested.flattenConcat().toList())
}
