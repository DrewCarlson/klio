import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun CoroutineScope.runOne(
    child: suspend CoroutineScope.(block: suspend CoroutineScope.() -> Unit) -> Unit
) {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    scope.child {
        val g = launch { throw TestEx() }
        println("g.parent === parent: " + (g.parent === parent))
        g.join()
    }
    parent.join()
    println("parent cancelled=${parent.isCancelled}")
}

fun main() = runBlocking {
    runOne { fail -> fail() }
    println("done")
}
