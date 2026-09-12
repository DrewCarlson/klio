// Stdlib operations compiled to C. A declaration with no Kotlin body is not a
// gap for the emitter to fill: the interpreter already implements it, named, in
// one table, and compiled code calls the SAME entry. That is why `List`, `Map`,
// `Set` and `String` need no second implementation here.
//
// A declaration reached through a receiver is registered under the
// receiver-qualified form — `substring` is declared in `kotlin.text` and
// implemented as `kotlin.String.substring` — and the declaration's own return
// type says whether the answer comes back as a machine type or stays a value.
import kotlin.math.max

fun main() {
    println("hello".substring(1, 3))
    println("a,b,c".replace(",", "-"))
    println("42".toInt() + 1)
    println("hello".uppercase())
}
