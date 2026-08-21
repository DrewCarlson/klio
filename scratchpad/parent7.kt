import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun CoroutineScope.runOne(
    name: String,
    child: suspend CoroutineScope.(block: suspend CoroutineScope.() -> Unit) -> Unit
) {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    scope.child {
        val g = launch { throw TestEx() }
        g.join()
    }
    parent.join()
    println("$name: parent cancelled=${parent.isCancelled}")
}

fun main() = runBlocking {
    // A: the child builder invokes the block through `launch`.
    runOne("A-launch") { fail -> launch { fail() } }
    println("done")
}
