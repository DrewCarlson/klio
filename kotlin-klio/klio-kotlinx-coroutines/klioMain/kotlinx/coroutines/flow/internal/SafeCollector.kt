package kotlinx.coroutines.flow.internal

import kotlinx.coroutines.flow.*
import kotlin.coroutines.*

// klio platform actual for the upstream `expect class SafeCollector`.
// The JVM actual is a ContinuationImpl that reuses a state machine
// and enforces the context-preservation / exception-transparency
// invariants across thread hand-offs. klio runs one cooperative,
// non-preemptive scheduler per `runBlocking`, so emissions are
// already serialized and stay on the collecting activation; the safe
// collector therefore only needs to forward each value downstream.
internal actual class SafeCollector<T> actual constructor(
    @JvmField internal actual val collector: FlowCollector<T>,
    @JvmField internal actual val collectContext: CoroutineContext
) : FlowCollector<T> {

    @JvmField
    internal actual val collectContextSize: Int =
        collectContext.fold(0) { count, _ -> count + 1 }

    public actual fun releaseIntercepted() {}

    actual override suspend fun emit(value: T) {
        collector.emit(value)
    }
}
