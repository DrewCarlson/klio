// A deadline competes with running work. A coroutine that only ever
// `yield()`s still hands control back, so a `withTimeout` around it fires on
// schedule, and a sibling `delay` still wakes while the loop spins — a timer
// is ready work in its own right, not something that waits for the run queue
// to drain.
//
// Run with: klio run examples/timeout_over_a_yield_loop.kt

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield

fun main() = runBlocking {
    // A busy loop with yields is still cancelled by its deadline.
    var spins = 0
    try {
        withTimeout(50) {
            while (true) {
                spins++
                yield()
            }
        }
        println("timeout   = never fired")
    } catch (e: TimeoutCancellationException) {
        println("timeout   = fired, loop ran " + (spins > 0))
    }

    // The `OrNull` form reports the same deadline as a null result.
    val outcome = withTimeoutOrNull(50) {
        while (true) {
            yield()
        }
        @Suppress("UNREACHABLE_CODE")
        "done"
    }
    println("orNull    = $outcome")

    // A sibling `delay` wakes while another coroutine spins on `yield`.
    var woke = false
    val sleeper = launch {
        delay(50)
        woke = true
    }
    var rounds = 0
    while (!woke && rounds < 1_000_000) {
        rounds++
        yield()
    }
    sleeper.join()
    println("sibling   = woke=$woke")

    // Work that finishes inside the deadline returns normally.
    val fast = withTimeout(10_000) {
        yield()
        "in time"
    }
    println("in budget = $fast")
}
