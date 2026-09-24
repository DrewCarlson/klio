// A `suspendCoroutineUninterceptedOrReturn` block that returns the
// `COROUTINE_SUSPENDED` it reads suspends the coroutine: the sentinel is one
// value however a program reads it, so the start hands it to its caller, and
// the completion runs only once the saved continuation resumes.
import kotlin.coroutines.*
import kotlin.coroutines.intrinsics.*

var saved: Continuation<Int>? = null

suspend fun parkHere(): Int = suspendCoroutineUninterceptedOrReturn { c ->
    saved = c
    COROUTINE_SUSPENDED
}

suspend fun answerNow(): Int = suspendCoroutineUninterceptedOrReturn { 7 }

fun main() {
    val block: suspend () -> Int = {
        println("body start")
        val now = answerNow()
        println("without suspending: $now")
        val v = parkHere()
        println("resumed with $v")
        v * 2
    }
    val completion = Continuation<Int>(EmptyCoroutineContext) { r -> println("completed with ${r.getOrNull()}") }
    val res = block.startCoroutineUninterceptedOrReturn(completion)
    println("start returned the sentinel: ${res === COROUTINE_SUSPENDED}")
    saved!!.resume(21)
    println("done")
}
