// klio cooperative dispatcher for the upstream kotlinx-coroutines
// runtime. klio runs one cooperative scheduler per `runBlocking`;
// `__kxco_spawn` posts work onto it (run after the current
// activation yields) and `__kxco_delayMillis` suspends in klio
// virtual time. Installed as the context `ContinuationInterceptor`
// by `newCoroutineContext` so upstream `launch` / `async` route the
// child through `dispatch` (deferred, not inline) and `delay`
// through `Delay.scheduleResumeAfterDelay`.

package kotlinx.coroutines

import kotlin.coroutines.*

internal fun __kxco_spawn(block: () -> Unit) {}
internal fun __kxco_delayMillis(millis: Long) {}

internal object KlioDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_spawn { block.run() }
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>
    ) {
        __kxco_spawn {
            __kxco_delayMillis(timeMillis)
            continuation.resumeWith(Result.success(Unit))
        }
    }
}

// klio runs one cooperative scheduler per `runBlocking`, so every
// standard dispatcher maps to `KlioDispatcher`: work is posted via
// `__kxco_spawn` and run when the current activation yields. Results
// of `async(Dispatchers.Default) { … }` are deterministic regardless
// of interleaving; the litmus asserts the computed value, not wall
// clock. `Main` needs the `MainCoroutineDispatcher` shape (its
// `immediate` is itself).
internal object KlioMainDispatcher : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher get() = this

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_spawn { block.run() }
    }
}

public actual object Dispatchers {
    public actual val Default: CoroutineDispatcher get() = KlioDispatcher
    public actual val Main: MainCoroutineDispatcher get() = KlioMainDispatcher
    public actual val Unconfined: CoroutineDispatcher get() = KlioDispatcher

    // `IO` is a JVM-only member (absent from the common `expect
    // object Dispatchers`), but common code and litmus programs use
    // `Dispatchers.IO` for blocking offload. Under the cooperative
    // scheduler it is the same dispatcher as the rest.
    public val IO: CoroutineDispatcher get() = KlioDispatcher
}
