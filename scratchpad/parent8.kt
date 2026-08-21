import kotlinx.coroutines.*

fun main() = runBlocking {
    val parent = CompletableDeferred<Unit>()
    val scope = CoroutineScope(coroutineContext + parent)
    val outer = coroutineContext[Job]
    // Explicit receiver.
    val a = scope.launch { }
    println("explicit parent is deferred: " + (a.parent === parent))
    // Implicit receiver through a receiver-lambda.
    suspend fun call(block: suspend CoroutineScope.() -> Job): Job = scope.block()
    val b = call { launch { } }
    println("implicit parent is deferred: " + (b.parent === parent) + " isOuter=" + (b.parent === outer))
    parent.cancel()
}
