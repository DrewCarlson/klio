// A dispatched coroutine body that throws must complete its Job as
// failed through the upstream machinery: the failure cancels the parent
// runBlocking job per structured concurrency, join() resumes with the
// cancellation (never hangs, never prints "after join"), and the
// exception crashes the run. kotlinc+kotlinx oracle: rc=1 with the
// IllegalStateException; "after join" is not printed.
//>! worker boom

import kotlinx.coroutines.*

fun main() = runBlocking {
    val j = launch(Dispatchers.Default) { throw IllegalStateException("worker boom") }
    j.join()
    println("after join")
}
