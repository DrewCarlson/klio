// Job.cancel must reach a coroutine dispatched on another pump: the
// Default child's delay is cancelled at its suspension point and the
// child body's side effects never become visible.
// kotlinc+kotlinx oracle output below.
//> end

import kotlinx.coroutines.*

fun main() = runBlocking {
    val job = launch {
        coroutineScope {
            launch(Dispatchers.Default) {
                delay(500)
                println("child done")
            }
        }
        println("scope done")
    }
    delay(100)
    job.cancel()
    job.join()
    println("end")
}
