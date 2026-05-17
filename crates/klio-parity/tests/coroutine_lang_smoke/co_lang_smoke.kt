// kotlin.coroutines language layer through the real shipping path.
// The pure upstream commonMain types (CoroutineContext,
// EmptyCoroutineContext, ContinuationInterceptor, Continuation) are
// consumed verbatim from the embedded stdlib; klio's platform layer
// supplies the intrinsic surface (suspendCoroutineUninterceptedOrReturn,
// startCoroutine, the slot-backed continuation) bridged onto the
// inline suspension engine.
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

class Sink<T> : Continuation<T> {
    override val context: CoroutineContext get() = EmptyCoroutineContext
    override fun resumeWith(result: Result<T>) {
        println("got=" + result.getOrThrow())
    }
}

suspend fun direct(): Int = suspendCoroutineUninterceptedOrReturn { 7 }

fun main() {
    val ctx: CoroutineContext = EmptyCoroutineContext
    //> EmptyCoroutineContext
    println(ctx.toString())
    //> true
    println(ctx[ContinuationInterceptor] == null)
    //> true
    println(ctx === (ctx + EmptyCoroutineContext))
    //> got=7
    ::direct.startCoroutine(Sink<Int>())
}
