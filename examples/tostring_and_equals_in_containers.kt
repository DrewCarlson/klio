// A class's `toString()` override renders its elements wherever a container is
// rendered — concatenated, interpolated, appended to a StringBuilder, or via
// `contentToString()`. Its `equals`/`hashCode` overrides decide membership
// wherever a container dedups, `distinct()` included.
//
// Run with: klio run examples/tostring_and_equals_in_containers.kt

class Box(val n: Int) {
    override fun equals(other: Any?): Boolean = other is Box && other.n == n
    override fun hashCode(): Int = n
    override fun toString(): String = "Box($n)"
}

// A class that overrides neither keeps identity semantics.
class Opaque(val n: Int)

fun main() {
    val b = Box(1)
    val xs = listOf(Box(1), Box(1), Box(2))

    // Every rendering route agrees.
    println("concat   = " + xs)
    println("template = $xs")
    println("toString = " + xs.toString())
    println("joined   = " + xs.joinToString())
    println("set      = " + xs.toSet())
    println("map      = " + mapOf(1 to b))
    println("pair     = " + (1 to b))
    println("nested   = " + listOf(listOf(b)))
    val sb = StringBuilder()
    sb.append(xs)
    println("appended = " + sb)
    println("array    = " + arrayOf(b).contentToString())

    // Dedup routes agree with `equals`/`hashCode`.
    println("distinct = " + xs.distinct())
    println("toSet    = " + xs.toSet().size)
    println("toMutable= " + xs.toMutableSet().size)
    println("hashSet  = " + HashSet(xs).size)
    println("contains = " + xs.contains(Box(2)))
    println("indexOf  = " + xs.indexOf(Box(2)))
    println("groupBy  = " + xs.groupBy { it }.size)
    println("distinctBy = " + xs.distinctBy { it }.size)

    // A class with no overrides keeps identity, so nothing collapses.
    val os = listOf(Opaque(1), Opaque(1))
    println("opaque   = " + os.distinct().size + "/" + os.toMutableSet().size)

    // `collection + element` is still the collection's own plus, not
    // concatenation, even when the element is a String.
    val names = listOf("a", "b")
    println("plus     = " + (names + "c"))
    println("plusList = " + (names + listOf("d")))
}
