// A CancellationException built with a cause keeps it: the two-argument
// factory, a cancellation a job is cancelled with, and the exception a
// cancelled coroutine observes all report the cause they were given.

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking

fun main() {
    val direct = CancellationException("stop", IllegalStateException("root"))
    println(direct.message)
    println(direct.cause?.message)
    println(CancellationException("no cause").cause)

    val job = Job()
    job.cancel(CancellationException("outer", RuntimeException("inner")))
    runBlocking {
        job.join()
        try {
            job.ensureActive()
        } catch (e: CancellationException) {
            println("caught ${e.message} cause=${e.cause?.message}")
        }
    }
}
