import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
suspend fun <R, T> FlowCollector<R>.helper(flows: Array<out Flow<*>>, arrayFactory: () -> Int?, tx: suspend FlowCollector<R>.(Array<T>) -> Unit) {
    @Suppress("UNCHECKED_CAST") val arr = arrayOf(1, 2) as Array<T>; tx(arr)
}
fun <T1, T2, R> Flow<T1>.combineX(flow: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> = flow {
    @Suppress("UNCHECKED_CAST")
    helper<R, Any?>(arrayOf(this@combineX, flow), { null }) { emit(transform(it[0] as T1, it[1] as T2)) }
}
fun main() = runBlocking { flowOf(1).combineX(flowOf("a")) { x, y -> "$x$y" }.collect { println(it) } }
