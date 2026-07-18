// A coroutineScope whose body throws cancels its children and rethrows only
// after they complete — including a child whose dispatched start task had not
// run yet. The pump used to drop queued-but-unstarted launches when the scope
// body's drive exited, so the cancelled child never completed and the scope
// (and every caller of it, e.g. runTest's teardown join) hung forever. A
// callbackFlow terminal (`first`) exercises the same shape through
// AbortFlowException.
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    try {
        coroutineScope {
            launch { try { delay(100000) } finally { println("child1 cancelled") } }
            throw RuntimeException("boom")
        }
    } catch (e: Exception) { println("caught $e") }

    try {
        coroutineScope {
            launch { try { delay(100000) } finally { println("child2 cancelled") } }
            throw CancellationException("abort-like")
        }
    } catch (e: CancellationException) { println("caught CancellationException") }

    val first = callbackFlow {
        trySend(41 + 1)
        awaitClose { println("producer closed") }
    }.first()
    println("first=$first")
}
