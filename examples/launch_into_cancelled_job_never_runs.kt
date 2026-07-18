// A coroutine launched into an already-cancelled Job never runs its body: the
// dispatcher's task observes the dead Job and resumes the START continuation
// with the CancellationException, which completes the coroutine without
// entering the body. klio's start continuation used to ignore a failure
// resume and run the body anyway.
import kotlinx.coroutines.*

fun main() = runBlocking {
    val job = Job(parent = coroutineContext[Job])
    job.cancel()
    val child = launch(Dispatchers.Default + job) {
        println("body ran (BAD)")
    }
    println("child.isCancelled=${child.isCancelled}")
    delay(10)
    println("done")
}
