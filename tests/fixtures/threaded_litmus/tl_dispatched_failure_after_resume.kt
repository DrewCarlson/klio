// The failure-completion edge on the RESUME path. tl_dispatched_failure_join
// throws before the body ever suspends, so the whole failure is handled on
// the thread that first ran it. Here the body suspends first, so the throw
// happens on whichever pool worker resumes the continuation — a different
// thread from the one that started it, reaching the machinery a cross-thread
// resume rebinds (an activation resumed on another worker once dereferenced
// the parker's dead thread-local state and segfaulted).
//
// Contract: identical to the pre-suspension case. The failure completes the
// Job as failed, cancels the parent per structured concurrency, and crashes
// the run; "after join" is never printed.
// kotlinc+kotlinx oracle: rc=1 with the IllegalStateException.
//>! boom after resume

import kotlinx.coroutines.*

fun main() = runBlocking {
    val j = launch(Dispatchers.Default) {
        delay(20)
        throw IllegalStateException("boom after resume")
    }
    j.join()
    println("after join")
}
