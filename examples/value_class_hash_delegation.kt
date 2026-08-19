// A `value` class hashes as its underlying property, and a `data` class folds
// each property's own `hashCode()`. When that property's class overrides
// `hashCode`, the override is what counts — so a wrapper around a mutable
// collection changes its hash as the collection changes, and two wrappers over
// equal contents agree.

class Counter {
    private val values = mutableListOf<Int>()

    fun add(v: Int) {
        values.add(v)
    }

    fun removeLast() {
        values.removeAt(values.size - 1)
    }

    override fun hashCode(): Int {
        var h = 0
        for (v in values) h += 31 * v
        return h
    }

    override fun equals(other: Any?): Boolean =
        other is Counter && other.values == values
}

@JvmInline
value class Tally(val counter: Counter)

data class Pair2(val left: Counter, val right: String)

fun main() {
    val a = Counter()
    val b = Counter()
    for (n in 1..3) {
        a.add(n)
        b.add(n)
    }

    // The value class delegates to the property's own hashCode.
    println("value class matches property : " + (Tally(a).hashCode() == a.hashCode()))
    println("equal contents agree         : " + (Tally(a).hashCode() == Tally(b).hashCode()))

    // Mutating the underlying collection changes the wrapper's hash.
    val before = Tally(a).hashCode()
    a.removeLast()
    println("hash tracks the property     : " + (Tally(a).hashCode() != before))
    println("differing contents differ    : " + (Tally(a).hashCode() != Tally(b).hashCode()))

    // A data class folds the property's override the same way.
    a.add(3)
    println("data class folds the override: " + (Pair2(a, "x").hashCode() == Pair2(b, "x").hashCode()))
    a.removeLast()
    println("data class tracks the change : " + (Pair2(a, "x").hashCode() != Pair2(b, "x").hashCode()))

    // equals and hashCode stay consistent.
    val eq = Tally(a) == Tally(b)
    println("equals agrees with hashCode  : " + (eq == (Tally(a).hashCode() == Tally(b).hashCode())))
}
