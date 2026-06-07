// The `flow { }` builder and terminal `collect` over the real
// upstream runtime: a cold flow emits across the SafeFlow /
// AbstractFlow / SafeCollector chain, plus `asFlow()` on a range.
//> e1
//> e2
//> e3
//> a1
//> a2
//> a3
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    flow {
        emit(1)
        emit(2)
        emit(3)
    }.collect { println("e$it") }
    (1..3).asFlow().collect { println("a$it") }
}
