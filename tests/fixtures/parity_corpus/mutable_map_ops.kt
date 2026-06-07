fun main() {
    val m = mutableMapOf("a" to 1, "b" to 2)
    m.merge("a", 10) { old, new -> old + new }
    m.merge("c", 5) { old, new -> old + new }
    println(m.entries.sortedBy { it.key }.map { "${it.key}=${it.value}" })

    println(m.putIfAbsent("a", 99))
    println(m.putIfAbsent("d", 7))
    println(m["d"])

    println(m.replace("b", 20))
    println(m.replace("z", 100))
    println(m["b"])

    val n = mutableMapOf(1 to "x")
    println(n.computeIfAbsent(2) { k -> "v$k" })
    println(n.computeIfAbsent(1) { k -> "nope" })
    println(n.computeIfPresent(1) { _, v -> v + "!" })
    println(n.computeIfPresent(9) { _, v -> v })
    println(n.compute(3) { k, v -> "${v}_$k" })
    println(n.entries.sortedBy { it.key }.map { "${it.key}=${it.value}" })

    // merge that removes (remapping returns null)
    val r = mutableMapOf("k" to 1)
    r.merge("k", 1) { _, _ -> null }
    println(r.containsKey("k"))
}
