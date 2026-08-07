fun main() {
    val set: MutableSet<Int> = mutableSetOf(1, 2, 3, 4)
    val asCollection: Collection<Int> = listOf(2, 3)
    val asIterable: Iterable<Int> = listOf(4)
    val asSequence: Sequence<Int> = sequenceOf(1)

    val a = mutableSetOf<Int>()
    a.addAll(asCollection)
    a.addAll(asIterable)
    a.addAll(asSequence)
    println(a.sorted().joinToString(","))

    println(set.containsAll(asCollection))
    set.removeAll(asCollection)
    set.removeAll(asIterable)
    set.removeAll(asSequence)
    println(set.joinToString(","))

    val m = mutableMapOf("a" to 1)
    m.putAll(mapOf("b" to 2))
    m.putAll(listOf("c" to 3))
    m.putAll(sequenceOf("d" to 4))
    m.putAll(arrayOf("e" to 5))
    println(m.keys.sorted().joinToString(","))
}
