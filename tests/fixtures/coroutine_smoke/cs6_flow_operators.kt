// Real upstream Flow intermediate operators over the cold-flow /
// SafeCollector chain: `map`, `filter`, `onEach`, `asFlow`, and the
// `toList` terminal compose through the operator fusion without the
// crossinline parameter recursing into the same-named operator.
//> m10
//> m20
//> f6
//> f8
//> f10
//> e1
//> e2
//> e3
//> [101, 102, 103]
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    flow {
        emit(1)
        emit(2)
    }.map { it * 10 }.collect { println("m$it") }
    (1..5).asFlow().map { it * 2 }.filter { it > 4 }.collect { println("f$it") }
    flow {
        emit(1)
        emit(2)
        emit(3)
    }.onEach { println("e$it") }.map { it + 100 }.toList().also { println(it) }
}
