// `Job.cancel` must preempt a `delay` loop dispatched onto a real worker
// thread. Each fresh suspension point installs its parent-cancellation
// handle through the suspending continuation's `context[Job]`, so the
// coroutine's own scope must survive every cross-pump resume hop: the
// dispatched pump-root's scope was dropped when its pump exited and the
// parked root was persisted, leaving every later `delay` with no `Job`
// in context — uncancellable, and the loop below out-lived its Job (the
// Recomposer-deadlock shape: one leaked writer thread per iteration).

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val job = Job(parent = coroutineContext[Job])
    var value = 0
    launch(Dispatchers.Default + job) {
        try {
            while (true) {
                value += 1
                delay(1)
            }
        } catch (e: CancellationException) {
            println("writer cancelled: ${e is CancellationException}")
            throw e
        } finally {
            println("writer finally")
        }
    }
    delay(20)
    job.cancel()
    job.join()
    println("writer advanced: ${value > 0}")
    println("joined")
}
