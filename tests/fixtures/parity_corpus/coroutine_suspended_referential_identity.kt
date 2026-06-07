// `COROUTINE_SUSPENDED` is a process singleton: `x ===
// COROUTINE_SUSPENDED` / `!==` are referential identity (and never
// dispatch a user `equals`). A `suspendCoroutineUninterceptedOrReturn
// { … }` whose block yields the sentinel must therefore detect it
// via the `outcome === COROUTINE_SUSPENDED` guard and suspend,
// instead of leaking the sentinel as a value.
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED

fun main() {
    val s: Any = COROUTINE_SUSPENDED
    println(s === COROUTINE_SUSPENDED)
    println(s !== COROUTINE_SUSPENDED)
    println(s === s)
    val other: Any = "x"
    println(other === COROUTINE_SUSPENDED)
    println(COROUTINE_SUSPENDED === COROUTINE_SUSPENDED)
    val box: Any? = if (s === COROUTINE_SUSPENDED) "suspend" else "value"
    println(box)
}
