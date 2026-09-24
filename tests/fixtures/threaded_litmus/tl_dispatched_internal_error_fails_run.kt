// A dispatched block whose body dies with an INTERNAL interpreter error
// (not a Kotlin throwable, so the failure never reaches the coroutine
// machinery and no resume can ever arrive for the parked root) must still
// end the run: the pool records the task's terminal failure and the parked
// runBlocking root surfaces it instead of idling forever. No valid program
// reaches an internal error here, so KLIO_FAULT_INJECT makes the call of
// `trigger` raise one; the run ends in an error naming it, and "done" is
// never printed.
//>env KLIO_FAULT_INJECT=internal-error@trigger
//>! injected internal error in `trigger`

import kotlinx.coroutines.*

fun trigger() {}

fun main() = runBlocking {
    withContext(Dispatchers.Default) {
        trigger()
    }
    println("done")
}
