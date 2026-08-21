// A `flow { }` builder preserves its collection context: every emission must
// come from the coroutine that is collecting it. Emitting from a child
// coroutine, or from a `withContext` block, violates the invariant and is
// reported rather than silently accepted — the value would otherwise arrive
// on a collector that is not thread-safe.
//
// Run with: klio run examples/flow_context_preservation.kt

import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.toList

fun firstLine(t: Throwable): String = (t.message ?: "").lineSequence().first()

fun main() = runBlocking {
    // Emitting from the collecting coroutine is the ordinary case.
    val direct = flow {
        emit(1)
        emit(2)
    }
    println("direct   = " + direct.toList())

    // A child coroutine is a different coroutine, so its emission is refused.
    val fromChild = flow {
        coroutineScope {
            launch { emit(1) }
        }
    }
    try {
        fromChild.collect { println("unreachable $it") }
    } catch (e: IllegalStateException) {
        println("child    = " + firstLine(e))
    }

    // Changing the context around an emission is refused for the same reason.
    val switched = flow {
        withContext(CoroutineName("other")) { emit(1) }
    }
    try {
        switched.collect { println("unreachable $it") }
    } catch (e: IllegalStateException) {
        println("switched = " + firstLine(e))
    }

    // `channelFlow` is the builder that DOES allow concurrent emission.
    val concurrent = channelFlow {
        launch { send(1) }
        launch { send(2) }
    }
    println("channel  = " + concurrent.toList().sorted())

    // `flowOn` moves the whole upstream, so the emission and the collection
    // agree again.
    val moved = flow {
        emit(1)
        emit(2)
    }.flowOn(CoroutineName("upstream"))
    println("flowOn   = " + moved.toList())
}
