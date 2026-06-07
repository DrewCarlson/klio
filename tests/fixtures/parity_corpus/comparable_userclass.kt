class Weight(val grams: Int) : Comparable<Weight> {
    override operator fun compareTo(other: Weight): Int {
        return grams - other.grams
    }
    override fun toString(): String = "${grams}g"
}

fun main() {
    val xs = listOf(Weight(300), Weight(100), Weight(200))
    val sorted = xs.sortedWith(compareBy { it.grams })
    for (w in sorted) {
        println(w)
    }
    val byNatural = xs.sorted()
    for (w in byNatural) {
        println(w)
    }
}
