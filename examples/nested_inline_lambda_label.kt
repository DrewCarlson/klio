// A lambda literal's implicit label is the inline function it is passed to,
// even when that function's body invokes it from inside a lambda it hands to
// another inline function with a same-named parameter: `return@outer` leaves
// the literal and the enclosing bodies run on. `suspendCoroutine` has this
// shape, since its body hands its `block` to `suspendCoroutineUninterceptedOrReturn`.
import kotlin.coroutines.*

inline fun <T> inner(crossinline block: (Int) -> Any?): T {
    val outcome = block(21)
    @Suppress("UNCHECKED_CAST")
    return outcome as T
}

inline fun <T> outer(crossinline block: (Int) -> Unit): T = inner { x ->
    block(x)
    x * 2
}

suspend inline fun <T> suspendingInner(crossinline block: (Int) -> Any?): T {
    val outcome = block(21)
    @Suppress("UNCHECKED_CAST")
    return outcome as T
}

suspend inline fun <T> suspendingOuter(crossinline block: (Int) -> Unit): T = suspendingInner { x ->
    block(x)
    x * 3
}

fun plain(skip: Boolean): Int = outer { x ->
    if (skip) {
        println("plain: left the literal at $x")
        return@outer
    }
    println("plain: ran through with $x")
}

suspend fun suspending(skip: Boolean): Int = suspendingOuter { x ->
    if (skip) {
        println("suspending: left the literal at $x")
        return@suspendingOuter
    }
    println("suspending: ran through with $x")
}

suspend fun viaSuspendCoroutine(fail: Boolean): Int = suspendCoroutine { c ->
    if (fail) {
        c.resumeWithException(IllegalStateException("refused"))
        return@suspendCoroutine
    }
    c.resume(5)
}

fun main() {
    println(plain(true))
    println(plain(false))
    val results = mutableListOf<String>()
    suspend {
        results += "${suspending(true)}"
        results += "${suspending(false)}"
        results += "${viaSuspendCoroutine(false)}"
        try {
            viaSuspendCoroutine(true)
            results += "no exception"
        } catch (e: IllegalStateException) {
            results += "caught ${e.message}"
        }
    }.startCoroutine(Continuation(EmptyCoroutineContext) { r -> println("completed: ${r.isSuccess}") })
    println(results.joinToString())
}
