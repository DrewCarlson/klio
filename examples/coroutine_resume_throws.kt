// A coroutine started with no dispatcher runs on the stack of whoever resumes
// it, so when its completion throws, the resumer's `resumeWith` throws.
import kotlin.coroutines.*
import kotlin.coroutines.intrinsics.*

val postponed = ArrayList<() -> Unit>()

suspend fun suspendWithException(e: Exception): String = suspendCoroutineUninterceptedOrReturn { x ->
    postponed.add { x.resumeWithException(e) }
    COROUTINE_SUSPENDED
}

suspend fun suspendWithValue(v: String): String = suspendCoroutineUninterceptedOrReturn { x ->
    postponed.add { x.resume(v) }
    COROUTINE_SUSPENDED
}

fun run(c: suspend () -> String) {
    c.startCoroutine(object : Continuation<String> {
        override val context = EmptyCoroutineContext
        override fun resumeWith(result: Result<String>) {
            println("completion succeeded: " + result.isSuccess)
            println("value: " + result.getOrThrow())
        }
    })
    while (postponed.isNotEmpty()) {
        postponed.removeAt(0)()
    }
}

fun main() {
    try {
        run { suspendWithException(Exception("boom")) }
        println("no exception")
    } catch (e: Exception) {
        println("caught " + e.message)
    }
    try {
        run { suspendWithValue("fine") }
        println("done")
    } catch (e: Exception) {
        println("caught " + e.message)
    }
}
