// Cross-package simple-name class collision (RC-A): kotlinx.io.Segment (public,
// concrete) vs kotlinx.coroutines.internal.Segment (internal, abstract). When both
// packs are co-loaded, a bare `Segment()` constructor inside kotlinx.io must resolve
// to the package-local concrete class, not the abstract coroutines twin. Before the
// FQN-keyed class reservation, the pre-pass collapsed both onto one slot (the
// coroutines one), so kotlinx.io's own `Segment()` misdispatched to its companion's
// `invoke` and a Buffer write that allocates a fresh segment failed (or, across
// coroutines, hung).
import kotlinx.io.*
import kotlinx.coroutines.*

fun main() {
    val b = Buffer()
    repeat(20000) { b.writeByte(1) }
    println("size=" + b.size)
}
