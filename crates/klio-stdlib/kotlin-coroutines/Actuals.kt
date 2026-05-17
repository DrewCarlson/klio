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
//  - SafeContinuation is the upstream JVM state machine ported to a
//    single-threaded plain field (klio is GIL-serialized, so the
//    lock-free CAS loop collapses to a straight-line `when`).

package kotlin.coroutines

import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED

// --- native host primitives (bound in klio-stdlib) ----------------

@PublishedApi
internal fun __klio_co_newSlot(): Long = 0L

// Parks the current activation indefinitely on `slot`; on resume the
// call yields the Result delivered by __klio_co_resume.
@PublishedApi
internal fun __klio_co_park(slot: Long): Result<Any?> = Result.success(null)

@PublishedApi
internal fun __klio_co_resume(slot: Long, ok: Boolean, value: Any?) {
}

// Drive `block` as a cooperative coroutine root to quiescence and
// return its terminal value (the start-coroutine driver boundary).
@PublishedApi
internal fun <T> __klio_co_runRoot(block: () -> T): T = block()

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

// --- SafeContinuation (upstream JVM logic, single-threaded) --------

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
        val cur = this.result
        when {
            cur === KlioCoState.UNDECIDED -> {
                this.result = result
            }
            cur === COROUTINE_SUSPENDED -> {
                this.result = KlioCoState.RESUMED
                delegate.resumeWith(result)
            }
            else -> throw IllegalStateException("Already resumed")
        }
    }

    @PublishedApi
    internal fun getOrThrow(): Any? {
        val cur = this.result
        if (cur === KlioCoState.UNDECIDED) {
            this.result = COROUTINE_SUSPENDED
            return COROUTINE_SUSPENDED
        }
        return when {
            cur === KlioCoState.RESUMED -> COROUTINE_SUSPENDED
            cur is Result<*> -> cur.getOrThrow()
            else -> cur
        }
    }
}
