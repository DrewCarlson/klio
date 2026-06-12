// A dispatched child's failure cancels the parent runBlocking job and
// rethrows out of runBlocking, where user code can catch it. The
// parent's delay is cancelled, so "not cancelled" never prints.
// kotlinc+kotlinx oracle output below.
//> escaped boom

import kotlinx.coroutines.*

fun main() {
    try {
        runBlocking {
            launch(Dispatchers.Default) { throw IllegalStateException("boom") }
            delay(200)
            println("not cancelled")
        }
        println("no exception")
    } catch (e: Throwable) {
        println("escaped " + e.message)
    }
}
