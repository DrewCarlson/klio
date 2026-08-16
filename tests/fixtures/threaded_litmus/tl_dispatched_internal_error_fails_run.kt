// A dispatched block whose body dies with an INTERNAL interpreter error
// (an unresolvable callee — not a Kotlin throwable, so the failure never
// reaches the coroutine machinery and no resume can ever arrive for the
// parked root) must still end the run: the pool records the task's
// terminal failure and the parked runBlocking root surfaces it instead
// of idling forever. kotlinc rejects this program at compile time
// (unresolved reference), so the pinned contract is klio's own
// fail-don't-hang guarantee: the run ends in an error naming the callee,
// and "done" is never printed.
//>! unresolved global `callDoesNotExist`

import kotlinx.coroutines.*

fun main() = runBlocking {
    withContext(Dispatchers.Default) {
        callDoesNotExist()
    }
    println("done")
}
