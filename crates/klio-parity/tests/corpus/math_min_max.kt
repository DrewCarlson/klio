import kotlin.math.min
import kotlin.math.max

fun main() {
    // Bare imported kotlin.math.min/max must not bind to the same-named
    // IntArray.min()/max() collection extensions.
    println(min(5, 1))
    println(max(5, 1))
    println(min(3.5, 2.1))
    println(max(3.5, 2.1))
    println(min(10L, 20L))
    println(max(10L, 20L))
    println(min(-1, -2))
    println(max(-1, -2))

    // Fully-qualified form resolves to the same intrinsic.
    println(kotlin.math.min(7, 9))
    println(kotlin.math.max(7, 9))

    // Mixed into expressions, including with the collection min()/max()
    // that genuinely operate on a receiver.
    val xs = intArrayOf(4, 2, 8, 1)
    println(xs.min())
    println(xs.max())
    println(min(xs.min(), 3))
    println(max(xs.max(), 3))

    var acc = 0
    for (v in xs) acc = max(acc, v)
    println(acc)
}
