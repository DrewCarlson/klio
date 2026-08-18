// A dispatched child that throws CancellationException is NOT a failure:
// kotlinx treats it as that coroutine's own normal cancellation, so it must
// not cancel the parent scope and must not crash the run. The neighbouring
// tl_dispatched_failure_* fixtures pin the opposite case (a real exception
// crashes the run), and the two are only one `throw` apart — this fixture
// exists so a change that collapses them is caught.
//> child cancelled=true
//> parent alive=true
//> root done

import kotlinx.coroutines.*

fun main() = runBlocking {
    val job = launch(Dispatchers.Default) {
        throw CancellationException("self")
    }
    job.join()
    println("child cancelled=${job.isCancelled}")
    // The parent scope must be untouched: a further dispatched child still
    // runs to completion after the cancelled sibling.
    val ok = launch(Dispatchers.Default) { delay(10) }
    ok.join()
    println("parent alive=${!ok.isCancelled && ok.isCompleted}")
    println("root done")
}
