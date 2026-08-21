package kotlinx.coroutines.flow.internal

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.coroutines.*

// klio platform actual for the upstream `expect class SafeCollector`.
// The JVM actual is a ContinuationImpl that reuses a state machine across
// emissions; klio runs one cooperative, non-preemptive scheduler per
// `runBlocking`, so the state-machine reuse buys nothing and each emission
// forwards straight downstream. The context-preservation invariant is not a
// thread-safety device though — it is part of the `flow` contract, and code
// that emits from another coroutine or another context must fail — so the
// shared `checkContext` runs on every context change exactly as it does on
// the JVM.
internal actual class SafeCollector<T> actual constructor(
    @JvmField internal actual val collector: FlowCollector<T>,
    @JvmField internal actual val collectContext: CoroutineContext
) : FlowCollector<T> {

    @JvmField
    internal actual val collectContextSize: Int =
        collectContext.fold(0) { count, _ -> count + 1 }

    // The context the previous emission ran in. Identity-compared, so a
    // run of emissions from one coroutine checks once.
    private var lastEmissionContext: CoroutineContext? = null

    public actual fun releaseIntercepted() {}

    actual override suspend fun emit(value: T) {
        // No cancellation check here: a plain `flow` is NOT cancellable by
        // default (that is what `cancellable()` is for), and the JVM
        // actual's `ensureActive` reads the EMITTER's continuation context,
        // not the collecting coroutine's. klio's `currentCoroutineContext()`
        // is the collecting coroutine's, so checking it here stops a flow
        // whose collector cancelled itself mid-collect.
        val currentContext = currentCoroutineContext()
        if (lastEmissionContext !== currentContext) {
            checkContext(currentContext)
            lastEmissionContext = currentContext
        }
        collector.emit(value)
    }
}
