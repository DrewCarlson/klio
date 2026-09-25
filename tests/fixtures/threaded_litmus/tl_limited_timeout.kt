// A coroutine on a `limitedParallelism(1)` view of a pool dispatcher waits
// inside `withTimeout` for a delay, a join and an await. The view has one
// worker, and each resume is dispatched to that worker. The timeout's own
// timer, and the delay's, must wait elsewhere; if the worker waited them out,
// each resume would sit behind the timer that could only end in a timeout.
// A sibling on the same view completes a latch the parent is waiting on, or
// completes a job after a delay of its own, a cancelled delay ends at once,
// and the IO view behaves the same. Under virtual time the sibling's delay
// must still come before the parent's timeout, though the sibling starts only
// after the parent has parked.
//> delay: ok
//> sibling latch: ok
//> sibling completer: ok
//> Default completer: ok
//> Default await: 4
//> long timeout: ok
//> cancelled delay: true
//> IO view: ok
//> order: [b, a]
import kotlinx.coroutines.*

@OptIn(ExperimentalCoroutinesApi::class)
fun main() = runBlocking {
    val limited = Dispatchers.Default.limitedParallelism(1)
    withContext(limited) {
        try {
            withTimeout(5000) { delay(100) }
            println("delay: ok")
        } catch (e: TimeoutCancellationException) {
            println("delay: timed out")
        }

        val latch = CompletableDeferred<Unit>()
        launch { latch.complete(Unit) }
        try {
            withTimeout(5000) { latch.await() }
            println("sibling latch: ok")
        } catch (e: TimeoutCancellationException) {
            println("sibling latch: timed out")
        }

        // The sibling runs only once the parent has parked, and delays first:
        // its timer must register before the parent's timeout can fire.
        val j2 = Job()
        launch { delay(100); j2.complete() }
        try {
            withTimeout(2000) { j2.join() }
            println("sibling completer: ok")
        } catch (e: TimeoutCancellationException) {
            println("sibling completer: timed out")
        }

        val j3 = Job()
        GlobalScope.launch(Dispatchers.Default) { delay(50); j3.complete() }
        try {
            withTimeout(5000) { j3.join() }
            println("Default completer: ok")
        } catch (e: TimeoutCancellationException) {
            println("Default completer: timed out")
        }

        val d4 = CompletableDeferred<Int>()
        GlobalScope.launch(Dispatchers.Default) { delay(50); d4.complete(4) }
        val got = try {
            withTimeout(5000) { d4.await() }.toString()
        } catch (e: TimeoutCancellationException) {
            "timed out"
        }
        println("Default await: $got")

        val j5 = Job()
        GlobalScope.launch(Dispatchers.Default) { delay(50); j5.complete() }
        try {
            withTimeout(60_000) { j5.join() }
            println("long timeout: ok")
        } catch (e: TimeoutCancellationException) {
            println("long timeout: timed out")
        }

        val sleeper = launch { delay(60_000) }
        delay(20)
        sleeper.cancelAndJoin()
        println("cancelled delay: ${sleeper.isCancelled}")
    }

    withContext(Dispatchers.IO.limitedParallelism(1)) {
        try {
            withTimeout(5000) { delay(50) }
            println("IO view: ok")
        } catch (e: TimeoutCancellationException) {
            println("IO view: timed out")
        }
    }

    // `a` suspends on its delay first, so `b` runs on the one worker meanwhile.
    val order = mutableListOf<String>()
    withContext(limited) {
        val a = launch { delay(100); order += "a" }
        val b = launch { order += "b" }
        joinAll(a, b)
    }
    println("order: $order")
}
