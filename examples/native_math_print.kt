// Stdlib functions with no Kotlin body compiled to C. `max`, `min` and `abs`
// have no declaration to compile — the implementation is the platform's — so
// the backend performs them directly. `abs` on the most negative value returns
// it unchanged, which the emitted negation does by wrapping unsigned rather
// than by negating a signed minimum, undefined in C. The floating forms are
// refused: Kotlin's `max` propagates NaN and orders -0.0 below 0.0, and C's
// `fmax` does neither.
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

fun main() {
    println(max(3, 7))
    println(min(3, 7))
    println(abs(-5))
    println(abs(5))
    println(max(2L, 9L))
    println(abs(-9L))
    print("a")
    print("b")
    println("c")
    print(1)
    println(2)
}
