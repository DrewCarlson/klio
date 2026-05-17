// kotlin.coroutines language layer through the real shipping path.
// The pure upstream commonMain types (CoroutineContext,
// EmptyCoroutineContext, ContinuationInterceptor, Continuation) are
// consumed verbatim from the embedded stdlib; klio's platform layer
// supplies the intrinsic surface (suspendCoroutineUninterceptedOrReturn,
// suspendCoroutine, SafeContinuation, startCoroutine, the slot-backed
// continuation) bridged onto the inline suspension engine.
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.coroutines.suspendCoroutine
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

class Sink<T> : Continuation<T> {
    override val context: CoroutineContext get() = EmptyCoroutineContext
    override fun resumeWith(result: Result<T>) {
        result.fold({ println("ok=" + it) }, { println("err=" + it.message) })
    }
}

suspend fun direct(): Int = suspendCoroutineUninterceptedOrReturn { 7 }

suspend fun viaSafe(): Int = suspendCoroutine { c -> c.resume(42) }

var saved: Continuation<Int>? = null
suspend fun parkAndAdd(): Int {
    val base = 100
    val r = suspendCoroutine<Int> { c -> saved = c }
    return base + r
}

suspend fun boom(): Int = suspendCoroutineUninterceptedOrReturn {
    throw IllegalStateException("kaboom")
}

fun main() {
    val ctx: CoroutineContext = EmptyCoroutineContext
    //> EmptyCoroutineContext
    println(ctx.toString())
    //> true
    println(ctx[ContinuationInterceptor] == null)
    //> true
    println(ctx === (ctx + EmptyCoroutineContext))
    //> ok=7
    ::direct.startCoroutine(Sink<Int>())
    //> ok=42
    ::viaSafe.startCoroutine(Sink<Int>())
    // Park, return to main, resume later: locals survive the
    // suspension and the result flows to the completion.
    ::parkAndAdd.startCoroutine(Sink<Int>())
    //> parked
    println("parked")
    //> ok=105
    saved!!.resume(5)
    // A thrown exception propagates to the completion.
    //> err=kaboom
    ::boom.startCoroutine(Sink<Int>())
}
