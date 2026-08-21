import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun <T> Flow<Flow<T>>.myFlatten(): Flow<T> = flow {
    collect { value -> emitAll(value) }
}

fun <T> Flow<Flow<T>>.myFlatten2(): Flow<T> = flow {
    val outer = this@myFlatten2
    outer.collect { value -> emitAll(value) }
}

fun main() = runBlocking {
    val nested: Flow<Flow<Int>> = flowOf(flowOf(1, 2), flowOf(3))
    println("direct emitAll = " + flow<Int> { emitAll(flowOf(7, 8)) }.toList())
    println("myFlatten      = " + nested.myFlatten().toList())
    println("myFlatten2     = " + nested.myFlatten2().toList())
}
