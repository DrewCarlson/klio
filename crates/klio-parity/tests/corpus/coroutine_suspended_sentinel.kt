// kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED is a single
// logical instance: identity-equal to itself, distinct from every
// other value, and stringifies to its own name.
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED

fun main() {
    val a = COROUTINE_SUSPENDED
    val b = COROUTINE_SUSPENDED
    println(a === b)
    println(a === COROUTINE_SUSPENDED)
    println(a == COROUTINE_SUSPENDED)
    val other: Any = 1
    println(other === COROUTINE_SUSPENDED)
    println(COROUTINE_SUSPENDED === "x")
    println(a.toString())
}
