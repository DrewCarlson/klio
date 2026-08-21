import kotlinx.coroutines.*

fun tokens(ctx: String): Any = "tok($ctx)"

suspend fun <T, V> undispatched(
    newContext: String,
    value: V,
    countOrElement: Any = tokens(newContext),
    block: suspend (V) -> T
): T {
    println("ctx=$newContext value=$value count=$countOrElement")
    return block(value)
}

interface Sink { suspend fun emit(v: Int) }

abstract class Op {
    protected abstract suspend fun flowCollect(collector: Sink)

    suspend fun collectWithContextUndispatched(collector: Sink, newContext: String) {
        return undispatched(newContext, block = { flowCollect(it) }, value = collector)
    }
}

class Impl : Op() {
    override suspend fun flowCollect(collector: Sink) {
        println("flowCollect got null? " + (collector == null))
        collector.emit(1)
    }
}

fun main() = runBlocking {
    val sink = object : Sink { override suspend fun emit(v: Int) { println("emit $v") } }
    Impl().collectWithContextUndispatched(sink, "ctx")
}
