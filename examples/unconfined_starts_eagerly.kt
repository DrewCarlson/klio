// `Dispatchers.Unconfined` reports `isDispatchNeeded == false`, so a coroutine
// launched under it executes on the caller's stack up to its first suspension
// instead of being queued: the launch returns only after `x = 1` ran. After the
// suspension it resumes on whatever thread performed the resume. `yield()`
// under Unconfined finds an empty event loop and returns without suspending.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

fun main() = runBlocking {
    var x = 0
    val job = launch(Dispatchers.Unconfined) {
        x = 1
        delay(10)
        x = 2
    }
    println("after launch x=$x")
    println("dispatcher: ${Dispatchers.Unconfined}")

    var yielded = false
    val loop = launch(Dispatchers.Unconfined) {
        yield()
        yielded = true
    }
    println("unconfined yield completed eagerly: $yielded")

    job.join()
    println("after join x=$x")
    loop.join()
}
