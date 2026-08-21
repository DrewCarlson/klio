import kotlinx.coroutines.*

class TestEx : Exception("boom")

fun main() = runBlocking {
    val parent = CompletableDeferred<Unit>(coroutineContext[Job])
    val scope = CoroutineScope(coroutineContext + parent)
    println("scope job is parent: " + (scope.coroutineContext[Job] === parent))
    val child = scope.launch {
        val g = launch { throw TestEx() }
        g.join()
        println("after grandchild join")
    }
    child.join()
    println("child cancelled=" + child.isCancelled)
    parent.join()
    println("parent active=" + parent.isActive + " cancelled=" + parent.isCancelled)
    println("done")
}
