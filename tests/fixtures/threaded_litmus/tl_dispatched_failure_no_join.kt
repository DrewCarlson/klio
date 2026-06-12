// The no-join variant of the failure-completion edge: nothing observes
// the child, but its failure still cancels the parent runBlocking job
// and crashes the run. kotlinc+kotlinx oracle: rc=1 with the exception;
// "root done" is not printed (the parent's delay is cancelled).
//>! worker boom

import kotlinx.coroutines.*

fun main() = runBlocking {
    launch(Dispatchers.Default) { throw IllegalStateException("worker boom") }
    delay(100)
    println("root done")
}
