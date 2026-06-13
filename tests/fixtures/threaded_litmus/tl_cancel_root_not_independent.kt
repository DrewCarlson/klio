// Cancelling the runBlocking root must not reach a coroutine launched on a
// fully independent `CoroutineScope(Job())` (outside the root's job tree).
// The independent coroutine resumes after the root is cancelled and runs a
// fresh cancellable `delay`; without the per-activation scope carrier that
// `delay` would bind to the resuming pump's root scope and the root cancel
// would over-deliver to it (A:OVERDELIVERY). With the carrier it keeps its
// own scope and completes (A:done). kotlinc+kotlinx oracle output below.
//> A:start
//> A:resumed
//> C:cancelling-root
//> A:done
//> main:saw-A-complete
//> end

import kotlinx.coroutines.*

fun main() {
    runBlocking {
        val done = CompletableDeferred<Unit>()
        CoroutineScope(Job()).launch {
            println("A:start")
            delay(10)
            println("A:resumed")
            try {
                delay(20)
                println("A:done")
            } catch (e: CancellationException) {
                println("A:OVERDELIVERY")
            }
            done.complete(Unit)
        }
        launch {
            delay(15)
            println("C:cancelling-root")
            coroutineContext[Job]!!.cancel()
        }
        done.await()
        println("main:saw-A-complete")
    }
    println("end")
}
