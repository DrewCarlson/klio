import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val nested: Flow<Flow<Int>> = flowOf(flowOf(1, 2), flowOf(3))
    println("flattenConcat = " + nested.flattenConcat().toList())
    val mapped: Flow<Flow<Int>> = (1..3).asFlow().map { v -> flow { emit(v) } }
    println("mapped        = " + mapped.flattenConcat().toList())
    println("mapMerge      = " + mapped.flattenMerge().toList())
}
