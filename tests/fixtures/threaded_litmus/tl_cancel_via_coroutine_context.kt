// `coroutineContext.cancel()` and `coroutineContext[Job]!!.cancel()` must
// both find the context's Job and cancel its children — the context
// element lookup resolves the installed Job in either call shape.
// kotlinc+kotlinx oracle output below.
//> c1-cancelled
//> c2-cancelled
//> end

import kotlinx.coroutines.*
import kotlin.coroutines.*

fun main() = runBlocking {
    val outer = CoroutineScope(Job())
    val c1 = outer.launch {
        try { delay(10000); println("c1-done") }
        catch (e: CancellationException) { println("c1-cancelled") }
    }
    yield()
    outer.coroutineContext.cancel()
    c1.join()

    val outer2 = CoroutineScope(Job())
    val c2 = outer2.launch {
        try { delay(10000); println("c2-done") }
        catch (e: CancellationException) { println("c2-cancelled") }
    }
    yield()
    outer2.coroutineContext[Job]!!.cancel()
    c2.join()
    println("end")
}
