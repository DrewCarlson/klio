import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun CoroutineScope.driver(
    child: suspend CoroutineScope.(block: suspend CoroutineScope.() -> Unit) -> Unit
) {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    println("outer job === parent: " + (scope.coroutineContext[Job] === parent))
    try {
        scope.child {
            println("inner job is parent's child: " + (coroutineContext[Job]?.parent === parent))
            val g = launch { throw TestEx() }
            g.join()
        }
        println("after child")
    } catch (e: Throwable) {
        println("caught " + e)
    }
    parent.join()
    println("parent cancelled=${parent.isCancelled}")
}

fun main() = runBlocking {
    driver { fail -> launch { fail() } }
    println("done")
}
