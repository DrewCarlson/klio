// Sibling B parks inside a `coroutineScope { }` (leaving its scope push on
// the active-scope stack); sibling A then resumes and starts a fresh
// cancellable `delay`. Without the per-activation scope carrier A's `delay`
// would bind its parent-cancellation handle to B's leftover scope, so
// cancelling B would over-deliver and cancel A. With the carrier each
// activation re-establishes its own scope on resume, so cancelling B leaves
// A alone. kotlinc+kotlinx oracle output below.
//> B:start
//> A:start
//> A:resumed
//> main:cancelling-B
//> A:done
//> main:end

import kotlinx.coroutines.*

fun main() = runBlocking {
    val b = launch {
        println("B:start")
        coroutineScope {
            delay(500)
        }
        println("B:done")
    }
    launch {
        println("A:start")
        delay(10)
        println("A:resumed")
        try {
            delay(100)
            println("A:done")
        } catch (e: CancellationException) {
            println("A:CANCELLED")
        }
    }
    delay(50)
    println("main:cancelling-B")
    b.cancel()
    delay(300)
    println("main:end")
}
