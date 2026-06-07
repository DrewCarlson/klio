// `mutableListOf(vararg)` delegates to the internal `Array.asArrayList()`
// helper. A bare call inside a member function lowers differently from a
// top-level call, so this exercises that the builder still returns the
// populated list (not Unit) when called from method scope.
class Builder {
    fun one(): MutableList<String> = mutableListOf("x")
    fun two(): MutableList<String> = mutableListOf("x", "y")
    fun none(): MutableList<String> = mutableListOf()
    fun viaListOf(): List<Int> = listOf(1, 2, 3)
    fun grow(): List<Int> {
        val acc = mutableListOf<Int>()
        for (i in 1..3) acc.add(i * i)
        acc.addAll(mutableListOf(100, 200))
        return acc
    }
}

fun main() {
    val b = Builder()
    println(b.one())
    println(b.two())
    println(b.none())
    println(b.viaListOf())
    println(b.grow())
    println(b.one().size)
}
