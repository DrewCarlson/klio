// A comparison on a type-parameter operand binds the bound's `compareTo` slot.
// The receiver may be host-backed or an interpreted class, and a same-named
// extension must not take the call from the member.

class Money(val cents: Int) : Comparable<Money> {
    override fun compareTo(other: Money): Int = cents - other.cents
    override fun toString(): String = "$" + cents
}

operator fun Money.compareTo(other: Int): Int = cents - other

fun <T : Comparable<T>> biggest(xs: List<T>): T {
    var best = xs[0]
    for (x in xs) if (x > best) best = x
    return best
}

fun <T : Comparable<T>> descending(xs: List<T>): List<T> {
    val out = xs.toMutableList()
    for (i in out.indices) for (j in 0 until out.size - 1 - i)
        if (out[j] < out[j + 1]) {
            val t = out[j]; out[j] = out[j + 1]; out[j + 1] = t
        }
    return out
}

fun main() {
    println(biggest(listOf(3, 9, 2)))
    println(biggest(listOf("pear", "apple", "zebra")))
    println(biggest(listOf(1.5, -2.0, 0.25)))
    println(biggest(listOf('a', 'z', 'm')))
    println(biggest(listOf(Money(5), Money(99), Money(1))))
    println(descending(listOf(3, 1, 2)))
    println(descending(listOf(Money(3), Money(1), Money(7))))
    val c: Comparable<Double> = 2.5
    println(c >= 2.0)
    // The member, not the extension, orders two Money values.
    println(Money(4) > Money(2))
    // The extension is still reachable when it is the only applicable one.
    println(Money(4) > 2)
}
