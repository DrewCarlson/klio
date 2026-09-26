// Forty pool tasks each start a 10 s timer and finish at once: a withTimeout
// whose body completes, or a delay another coroutine cancels. No task is left
// waiting, so the tasks join, and a task dispatched afterwards starts, well
// before any timer would fire. A task that waited out its timer would hold
// its worker for 10 s.
//> IO withTimeout: joined promptly, a later task ran promptly
//> Default withTimeout: joined promptly, a later task ran promptly
//> IO cancelled delay: joined promptly, a later task ran promptly
import kotlinx.coroutines.*
import kotlin.time.TimeSource

suspend fun check(name: String, dispatcher: CoroutineDispatcher, body: suspend () -> Unit) {
    val t0 = TimeSource.Monotonic.markNow()
    coroutineScope {
        List(40) { launch(dispatcher) { body() } }.joinAll()
    }
    val joined = t0.elapsedNow().inWholeMilliseconds
    val ran = withContext(dispatcher) { t0.elapsedNow().inWholeMilliseconds }
    fun verdict(ms: Long) = if (ms < 5_000) "promptly" else "after ${ms / 1000}s"
    println("$name: joined ${verdict(joined)}, a later task ran ${verdict(ran)}")
}

fun main() = runBlocking {
    check("IO withTimeout", Dispatchers.IO) { withTimeout(10_000) { yield() } }
    check("Default withTimeout", Dispatchers.Default) { withTimeout(10_000) { yield() } }
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    check("IO cancelled delay", Dispatchers.IO) {
        val timer = scope.launch { delay(10_000) }
        yield()
        timer.cancel()
    }
}
