import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    flow {
        println("in flow, name=" + coroutineContext[CoroutineName]?.name)
        emit(1)
        emit(2)
    }
        .flowOn(CoroutineName("Name"))
        .collect { v -> println("got $v") }
    println("done")
}
