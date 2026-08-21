import kotlinx.coroutines.*

class TestEx : Exception("boom")

suspend fun variant(name: String, parent: Job, scope: CoroutineScope) {
    val child = scope.launch { throw TestEx() }
    child.join()
    println("$name: child cancelled=${child.isCancelled} parentActive=${parent.isActive}")
}

fun main() = runBlocking {
    run {
        val p = Job(coroutineContext[Job])
        variant("plainJob", p, CoroutineScope(coroutineContext + p))
        p.cancel()
    }
    run {
        val p = CompletableDeferred<Unit>(coroutineContext[Job])
        variant("deferred", p, CoroutineScope(coroutineContext + p))
        p.cancel()
    }
    println("done")
}
