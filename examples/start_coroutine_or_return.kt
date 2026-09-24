// `startCoroutineUninterceptedOrReturn` gives its caller the body's value when
// the body finishes without suspending, and COROUTINE_SUSPENDED when it
// suspends, delivering the result to the completion later. A body that
// throws before suspending throws to the caller, whatever an earlier start
// did.
import kotlin.coroutines.*
import kotlin.coroutines.intrinsics.*

suspend fun suspendHere(): String = suspendCoroutineUninterceptedOrReturn { c ->
    c.resume("resumed")
    COROUTINE_SUSPENDED
}

fun start(label: String, body: suspend () -> String) {
    var delivered: String? = null
    val result = try {
        body.startCoroutineUninterceptedOrReturn(object : Continuation<String> {
            override val context: CoroutineContext get() = EmptyCoroutineContext
            override fun resumeWith(result: Result<String>) {
                delivered = result.getOrElse { "failure " + it.message }
            }
        })
    } catch (e: RuntimeException) {
        "threw " + e.message
    }
    val shown = if (result === COROUTINE_SUSPENDED) "suspended" else result
    println("$label: returned $shown, completion got $delivered")
}

fun main() {
    start("direct") { "value" }
    start("suspends") { suspendHere() }
    start("throws") { throw RuntimeException("early") }
    start("suspends again") { suspendHere() + "!" }
}
