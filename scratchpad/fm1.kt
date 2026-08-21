import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val a = (1..6).asFlow().flatMapMerge(concurrency = 2) { v -> flow { emit(v * 10) } }
    println("named   = " + a.toList())
    val b = (1..6).asFlow().flatMapMerge { v -> flow { emit(v) } }
    println("default = " + b.toList())
    val c = (1..6).asFlow().flatMapConcat { v -> flow { emit(v) } }
    println("concat  = " + c.toList())
    val d = flowOf(flowOf(1, 2), flowOf(3)).flattenMerge(concurrency = 2)
    println("flatten = " + d.toList())
}
