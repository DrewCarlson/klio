// A resume of a Dispatchers.Unconfined coroutine runs it on the resuming
// thread before resume returns, whichever thread last ran it. The first
// coroutine's timeout fires on the timer thread, which runs it on to its next
// wait; main's next resume must still run it inline, so the event right after
// finds it waiting again (a tap's release after its press). The second is
// parked by runBlocking's thread and resumed by a Dispatchers.Default
// coroutine, which on the JVM runs it on the worker before continuing.
//> got a
//> second: null
//> got b
//> second: c
//> A resuming B
//> B resumed on the resumer's thread: true
//> A continues after resume
//> done
import kotlin.coroutines.resume
import kotlinx.coroutines.*

var waiter: CancellableContinuation<String>? = null

suspend fun awaitEvent(): String = suspendCancellableCoroutine { waiter = it }

fun send(e: String) {
    val w = waiter
    if (w == null) {
        println("dropped $e")
        return
    }
    waiter = null
    w.resume(e)
}

fun main() {
    val scope = CoroutineScope(Dispatchers.Unconfined)
    scope.launch {
        while (true) {
            val first = awaitEvent()
            println("got $first")
            val second = withTimeoutOrNull(300) { awaitEvent() }
            println("second: $second")
        }
    }
    send("a")
    runBlocking { delay(1000) }
    send("b")
    send("c")
    scope.cancel()

    runBlocking {
        var cont: CancellableContinuation<Unit>? = null
        val parked = CompletableDeferred<Unit>()
        val b = launch(Dispatchers.Unconfined) {
            suspendCancellableCoroutine<Unit> { cont = it; parked.complete(Unit) }
            val worker = Thread.currentThread().name.startsWith("DefaultDispatcher-worker")
            println("B resumed on the resumer's thread: $worker")
            suspendCancellableCoroutine<Unit> { }
        }
        parked.await()
        launch(Dispatchers.Default) {
            println("A resuming B")
            cont!!.resume(Unit)
            println("A continues after resume")
        }.join()
        b.cancel()
    }
    println("done")
}
