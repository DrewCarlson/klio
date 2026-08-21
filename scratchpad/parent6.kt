import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun CoroutineScope.body() {
    val g = launch { throw TestEx() }
    g.join()
    println("joined")
}

fun main() = runBlocking {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    scope.launch { body() }
    println("after launch")
    parent.join()
    println("parent cancelled=${parent.isCancelled}")
    println("done")
}
