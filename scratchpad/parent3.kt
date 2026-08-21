import kotlinx.coroutines.*

class TestEx : Exception("boom")

fun main() = runBlocking {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    val child = scope.launch { throw TestEx() }
    child.join()
    println("child cancelled=${child.isCancelled}")
    parent.join()
    println("parent active=${parent.isActive} cancelled=${parent.isCancelled}")
    println("done")
}
