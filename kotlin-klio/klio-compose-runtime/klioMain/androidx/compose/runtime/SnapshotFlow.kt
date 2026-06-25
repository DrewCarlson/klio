// snapshotFlow + Flow.collectAsState — bridges between compose's observable
// state and kotlinx.coroutines Flows.
//
// snapshotFlow emits block()'s value, then re-emits (distinct) whenever a state
// object block read is written. The wait-for-change suspends on a conflated
// channel — outside any lock — so it drives correctly under the recomposer's
// coroutine scope. collectAsState mirrors a Flow into a compose State via a
// LaunchedEffect.

package androidx.compose.runtime

import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** A cold Flow of [block]'s value, re-emitted (when changed) whenever a state
 * object read inside [block] is written. */
public fun <T> snapshotFlow(block: () -> T): Flow<T> = flow {
    val changes = Channel<Unit>(Channel.CONFLATED)
    var subscribed: Set<Any> = emptySet()
    val unregister = StateObservation.registerWriteObserver { state ->
        if (state in subscribed) changes.trySend(Unit)
    }
    fun evaluate(): T {
        val reads = HashSet<Any>()
        val result = StateObservation.observe({ s -> reads.add(s) }, block)
        subscribed = reads
        return result
    }
    try {
        var last = evaluate()
        emit(last)
        while (true) {
            changes.receive()
            val next = evaluate()
            if (next != last) {
                last = next
                emit(next)
            }
        }
    } finally {
        unregister()
    }
}

/** Collect this Flow into a compose [State], starting at [initial]. */
@Composable
public fun <T> Flow<T>.collectAsState(
    initial: T,
    context: CoroutineContext = EmptyCoroutineContext,
): State<T> {
    val flow = this
    val state = remember { mutableStateOf(initial) }
    LaunchedEffect(flow, context) {
        if (context == EmptyCoroutineContext) {
            flow.collect { state.value = it }
        } else {
            withContext(context) { flow.collect { state.value = it } }
        }
    }
    return state
}

/** Collect this StateFlow into a compose [State], starting at its current value. */
@Composable
public fun <T> StateFlow<T>.collectAsState(
    context: CoroutineContext = EmptyCoroutineContext,
): State<T> = collectAsState(value, context)
