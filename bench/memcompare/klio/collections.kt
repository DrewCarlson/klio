// Object-graph / GC workload: build 1M records, group by key into a map of
// lists, aggregate per group, sort groups by total. Stresses the heap with many
// small live objects and a churny build phase.

class Rng(seed: Long) {
    private var s = seed and 0x7fffffffL
    fun next(): Long {
        s = (s * 1103515245L + 12345L) and 0x7fffffffL
        return s
    }
}

fun main() {
    val n = 1_000_000
    val groups = 1000
    val rng = Rng(12345L)
    val byKey = HashMap<Int, MutableList<Long>>()
    var totalSum = 0L
    for (i in 0 until n) {
        val v = rng.next()
        val k = i % groups
        byKey.getOrPut(k) { ArrayList() }.add(v)
        totalSum += v
    }
    val sums = ArrayList<Pair<Int, Long>>(byKey.size)
    for ((k, vs) in byKey) {
        var s = 0L
        for (v in vs) s += v
        sums.add(Pair(k, s))
    }
    sums.sortByDescending { it.second }
    val top = sums[0]
    println("collections: records=$n groups=${byKey.size} totalSum=$totalSum topKey=${top.first} topSum=${top.second}")
}
