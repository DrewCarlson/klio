import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun CoroutineScope.body() {
    var unhandled: Throwable? = null
    val handler = CoroutineExceptionHandler { _, e -> unhandled = e }
    val grandchild = launch(handler) { throw TestEx() }
    grandchild.join()
    println("unhandled=" + (unhandled?.message ?: "null"))
}

fun main() = runBlocking {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    try {
        scope.launch { body() }
        println("after launch")
    } catch (e: Throwable) {
        println("caught " + e)
    }
    parent.join()
    println("parent active=${parent.isActive} cancelled=${parent.isCancelled}")
    println("done")
}
