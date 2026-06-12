// klio platform layer for kotlin.coroutines.
//
// The pure kotlin.coroutines commonMain sources (CoroutineContext,
// CoroutineContextImpl, ContinuationInterceptor, Continuation) are
// consumed verbatim from the upstream Kotlin stdlib checkout (see the
// pack_builder curated include list). Those files reach a small set
// of genuinely platform/intrinsic declarations that every Kotlin
// backend must supply. klio has no compiler-generated coroutine state
// machine: it runs `suspend` functions inline and parks an activation
// cooperatively at a suspension point. This file (and the sibling
// Intrinsics.kt) is klio's platform layer over that model:
//
//  - the three __klio_co_* host primitives (slot allocation, an
//    indefinite value-carrying park, and a resume that delivers a
//    Result to the parked activation) are bound natively in
//    klio-stdlib and bridge onto the interpreter's frame-snapshot
//    suspension engine.
//  - SafeContinuation is the upstream JVM state machine with the
//    lock-free CAS loop replaced by monitor-guarded transitions
//    (`kotlin.synchronized` on the instance), so a resume arriving
//    from a worker thread races safely against the suspending
//    caller's `getOrThrow`.

package kotlin.coroutines

import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED

// --- native host primitives (bound in klio-stdlib) ----------------

@PublishedApi
internal fun __klio_co_newSlot(): Long = 0L

// Bind the next suspension (even a timed `delay`) to `slot` without
// suspending now, so a suspend inside a
// `suspendCoroutineUninterceptedOrReturn` block stays reachable via
// the continuation's slot for preemptive cancellation.
@PublishedApi
internal fun __klio_co_armSlot(slot: Long) {}

@PublishedApi
internal fun __klio_co_disarmSlot() {}

// Parks the current activation indefinitely on `slot`; on resume the
// call yields the Result delivered by __klio_co_resume.
@PublishedApi
internal fun __klio_co_park(slot: Long): Result<Any?> = Result.success(null)

@PublishedApi
internal fun __klio_co_resume(slot: Long, ok: Boolean, value: Any?) {
}

// Make `scope` the active coroutine scope for an undispatched block
// running inline in the caller's activation, so the suspend-implicit
// `coroutineContext` inside the block resolves to the block's own
// coroutine (a `ScopeCoroutine` / `TimeoutCoroutine`). Balanced by
// __klio_co_popScope when the block's activation completes.
@PublishedApi
internal fun __klio_co_pushScope(scope: Any?) {}

@PublishedApi
internal fun __klio_co_popScope() {}

// Drive `block` as a cooperative coroutine root to quiescence (the
// start-coroutine driver boundary). `block` delivers its own result
// to the completion continuation, so this returns nothing — a
// suspension inside `block` parks the whole activation, including
// the pending completion delivery.
//
// `scope` is the coroutine the block belongs to (the completion, which
// for `async`/`launch` is the `AbstractCoroutine` itself). The driver
// makes it the active `CoroutineScope` while the block runs so a
// suspend-implicit `coroutineContext` read inside resolves to the
// coroutine's own context — including its `Job` — instead of the
// inherited root scope.
@PublishedApi
internal fun __klio_co_runRoot(scope: Any?, block: () -> Unit): Unit = block()

// --- the continuation klio hands to a suspendCoroutine block -------

@PublishedApi
internal class KlioContinuation<T>(
    private val slot: Long,
    public override val context: CoroutineContext
) : Continuation<T> {
    public override fun resumeWith(result: Result<T>) {
        val ok = result.isSuccess
        __klio_co_resume(slot, ok, if (ok) result.getOrNull() else result.exceptionOrNull())
    }
}

// --- SafeContinuation (upstream JVM logic) -------------------------
//
// The JVM actual runs its UNDECIDED/SUSPENDED/RESUMED transitions
// through an atomic CAS because a continuation captured inside a
// `suspendCoroutine` block can be resumed from another thread (a
// `Dispatchers.Default` worker) while the suspending caller races
// through `getOrThrow`. klio's workers are real OS threads, so the
// transitions here hold the instance's monitor (`kotlin.synchronized`,
// the host's per-object reentrant lock): each state step is observed
// atomically, and the delegate resume runs outside the monitor exactly
// like the upstream post-CAS resume.

private enum class KlioCoState { UNDECIDED, RESUMED }

@PublishedApi
internal class SafeContinuation<in T> @PublishedApi internal constructor(
    private val delegate: Continuation<T>,
    initialResult: Any?
) : Continuation<T> {
    @PublishedApi
    internal constructor(delegate: Continuation<T>) : this(delegate, KlioCoState.UNDECIDED)

    public override val context: CoroutineContext
        get() = delegate.context

    private var result: Any? = initialResult

    public override fun resumeWith(result: Result<T>) {
        val resumeDelegate = kotlin.synchronized(this) {
            val cur = this.result
            when {
                cur === KlioCoState.UNDECIDED -> {
                    this.result = result
                    false
                }
                cur === COROUTINE_SUSPENDED -> {
                    this.result = KlioCoState.RESUMED
                    true
                }
                else -> throw IllegalStateException("Already resumed")
            }
        }
        if (resumeDelegate) {
            delegate.resumeWith(result)
        }
    }

    @PublishedApi
    internal fun getOrThrow(): Any? {
        val cur = kotlin.synchronized(this) {
            val seen = this.result
            if (seen === KlioCoState.UNDECIDED) {
                this.result = COROUTINE_SUSPENDED
            }
            seen
        }
        return when {
            cur === KlioCoState.UNDECIDED -> COROUTINE_SUSPENDED
            cur === KlioCoState.RESUMED -> COROUTINE_SUSPENDED
            cur is Result<*> -> cur.getOrThrow()
            else -> cur
        }
    }
}
