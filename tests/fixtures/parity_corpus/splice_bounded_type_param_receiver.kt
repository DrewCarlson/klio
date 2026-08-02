fun <K, V, M : MutableMap<K, MutableList<V>>> fill(dest: M, pairs: List<Pair<K, V>>): M {
    for ((k, v) in pairs) {
        val bucket = dest.getOrPut(k) { mutableListOf() }
        bucket.add(v)
    }
    return dest
}

fun main() {
    val grouped = listOf(1 to "a", 2 to "b", 1 to "c").groupByTo(mutableMapOf()) { it.second }
    println(grouped.keys.sorted())
    println(grouped["a"])
    val m = fill(mutableMapOf<String, MutableList<Int>>(), listOf("x" to 1, "x" to 2, "y" to 3))
    println(m["x"])
    println(m["y"])
}
