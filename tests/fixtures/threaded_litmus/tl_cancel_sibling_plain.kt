// Cancelling one launched sibling must not cancel another. Control for the
// active-scope-carrier fix: a plain `delay` sibling already resolves its own
// cancellation scope, so cancelling B leaves A's post-resume `delay` alone.
// kotlinc+kotlinx oracle output below.
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
        delay(500)
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
