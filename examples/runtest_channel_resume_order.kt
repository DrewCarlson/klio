// A channel delivery to a coroutine on the runTest scheduler is DISPATCHED
// through that scheduler, so it stays ordered with the tasks around it: after
// `trySend` + `yield()` the collector has run. klio's native channel resume
// used to bypass the waiter's dispatcher and queue on the raw pump, which the
// runTest body starves — the collector only ran after the body finished.
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield

fun main() = runTest {
    val ch = Channel<Unit>(1)
    var count = 0
    val job = launch {
        while (true) {
            ch.receive()
            count++
        }
    }
    yield()
    println("collector started, count=$count")
    ch.trySend(Unit)
    yield()
    println("after trySend+yield count=$count")
    job.cancel()
    println("done")
}
