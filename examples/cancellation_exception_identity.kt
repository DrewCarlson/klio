// kotlinx.coroutines' CancellationException is the stdlib's
// kotlin.coroutines.cancellation.CancellationException under another name:
// either name builds, catches and tests the same exception, and `Job.cancel`
// takes one built through either.

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

typealias StdCancellation = kotlin.coroutines.cancellation.CancellationException

fun main() = runBlocking {
    val fromCoroutines = CancellationException("coroutines")
    val fromStdlib = StdCancellation("stdlib")
    println(fromCoroutines is StdCancellation)
    println(fromStdlib is CancellationException)
    println(fromCoroutines is IllegalStateException)

    val first = launch {
        try {
            awaitCancellation()
        } catch (e: StdCancellation) {
            println("caught ${e.message} as the stdlib's")
        }
    }
    yield()
    first.cancel(StdCancellation("std"))
    first.join()

    val second = launch {
        try {
            awaitCancellation()
        } catch (e: CancellationException) {
            println("caught ${e.message} as the coroutines'")
        }
    }
    yield()
    second.cancel(CancellationException("kx", IllegalArgumentException("why")))
    second.join()
    println(second.isCancelled)

    var seen: Throwable? = null
    val third = launch {
        try {
            awaitCancellation()
        } catch (e: Throwable) {
            seen = e
            throw e
        }
    }
    yield()
    third.cancel()
    third.join()
    println(seen is StdCancellation)
    println(seen?.message)
}
