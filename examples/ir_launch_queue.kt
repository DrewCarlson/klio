// Phase F deliverable: the `launch { … }` shim posts its block onto
// the enclosing runBlocking's scheduler queue (via __kxco_spawn)
// instead of running inline. After the main body completes, the
// scheduler drains queued launches in FIFO order. Sequential by
// design — klio is single-threaded — but the queueing makes it a
// real scheduler rather than an inline call.

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.__kxco_spawn
import kotlinx.coroutines.delay

fun main() {
    runBlocking {
        println("main start")
        __kxco_spawn { runBlocking {
            println("A1")
            delay(1L)
            println("A2")
        } }
        __kxco_spawn { runBlocking {
            println("B1")
            delay(1L)
            println("B2")
        } }
        println("main end")
    }
    println("done")
}
