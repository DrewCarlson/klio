// A `vararg` primary constructor packs trailing positional arguments
// into the vararg array for a direct `Klass(a, b, c)` call, a single
// `Klass(a)` argument, and a bare `Klass()` (empty vararg) — the same
// way a `vararg` top-level function does. A leading fixed parameter is
// bound first, then the rest collect into the vararg slot. A spread
// `Klass(*arr)` forwards the array verbatim.
class Tags(vararg xs: String) {
    val joined: String = mutableListOf(*xs).joinToString(",")
    val count: Int = xs.size
}

class Labeled(val tag: String, vararg xs: Int) {
    val sum: Int = xs.sum()
    val count: Int = xs.size
    fun render() = "$tag=$sum/$count"
}

fun main() {
    println(Tags("a", "b", "c").joined)
    println(Tags("solo").joined)
    println("empty:[${Tags().joined}]/${Tags().count}")

    println(Labeled("x", 1, 2, 3).render())
    println(Labeled("y").render())

    val arr = intArrayOf(4, 5, 6)
    println(Labeled("z", *arr).render())
}
