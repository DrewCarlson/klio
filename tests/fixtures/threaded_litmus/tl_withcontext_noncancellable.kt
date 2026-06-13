// `withContext(NonCancellable)` (and any context-changing `withContext`
// whose dispatcher is unchanged) takes the undispatched fast path: it
// builds an `UndispatchedCoroutine` over `ScopeCoroutine` and runs the
// block inline, returning its value through a `return@sc` out of the
// inlined `withCoroutineContext`. The block must run exactly once and the
// result must flow back. kotlinc+kotlinx oracle output below.
//> inside-noncancellable
//> ctx-result=7
//> done

import kotlinx.coroutines.*

fun main() = runBlocking {
    withContext(NonCancellable) {
        println("inside-noncancellable")
    }
    val r = withContext(CoroutineName("probe")) {
        7
    }
    println("ctx-result=$r")
    println("done")
}
