// An extension property may carry its own type parameters
// (`var <T> Box<T>.value: T`). Upstream kotlinx-coroutines uses this
// for WorkaroundAtomicReference.value.
class Box<V>(var v: V)

var <T> Box<T>.value: T
    get() = this.v
    set(x) { this.v = x }

val <T> Box<T>.shown: String get() = "box(" + this.v + ")"

fun main() {
    val b = Box(1)
    b.value = 7
    println(b.value)
    println(b.shown)
}
