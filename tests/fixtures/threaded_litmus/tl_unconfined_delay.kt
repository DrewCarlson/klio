// Launches on Dispatchers.Unconfined from plain code, with no runBlocking.
// Each body runs on the caller's stack to its first delay, and the launch
// returns there: the delay waits on the timer thread, not on the caller. A
// body looping on a delay (a cursor blink) must not keep its caller,
// a delay of Long.MAX_VALUE / 2 - 1 (a tap detector's timeout) must neither
// overflow nor fire, and a cancel ends each one. The last case resumes one
// coroutine by hand while another waits on that huge delay. The loop's delay
// is long, so a machine too loaded to reach the cancel within it under
// virtual time, whose clock never runs slower than real time, still ticks
// only if the launch never returned.
//> started
//> launched
//> done
//> waiting
//> launched 2
//> cancelled true
//> launched 3
//> resumed
//> done 3
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.*

fun main() {
    val scope = CoroutineScope(Dispatchers.Unconfined)
    scope.launch {
        println("started")
        while (true) {
            delay(30_000)
            println("tick")
        }
    }
    println("launched")
    scope.cancel()
    println("done")

    val scope2 = CoroutineScope(Dispatchers.Unconfined)
    val job = scope2.launch {
        println("waiting")
        delay(Long.MAX_VALUE / 2 - 1)
        println("woke")
    }
    println("launched 2")
    job.cancel()
    println("cancelled ${job.isCancelled}")

    val scope3 = CoroutineScope(Dispatchers.Unconfined)
    var cont: Continuation<Unit>? = null
    val timeout = scope3.launch {
        delay(Long.MAX_VALUE / 2 - 1)
        delay(1)
        println("timed out")
    }
    scope3.launch {
        suspendCoroutine<Unit> { cont = it }
        println("resumed")
    }
    println("launched 3")
    cont!!.resume(Unit)
    timeout.cancel()
    println("done 3")
}
