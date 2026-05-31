fun main() {
    val m = mutableMapOf("a" to 1, "b" to 2, "c" to 3)
    m.keys.remove("b")
    println(m)

    val m2 = mutableMapOf("a" to 1, "b" to 2, "c" to 3)
    for (e in m2.entries) { if (e.value % 2 == 1) e.setValue(e.value * 10) }
    println(m2)

    val m3 = mutableMapOf("x" to 10, "y" to 20, "z" to 10)
    m3.values.remove(10)
    println(m3)

    val m4 = mutableMapOf(1 to "a", 2 to "b", 3 to "c", 4 to "d")
    m4.keys.removeAll(setOf(1, 3))
    println(m4)

    val m5 = mutableMapOf(1 to "a", 2 to "b", 3 to "c")
    m5.keys.retainAll(setOf(2, 3))
    println(m5)

    val m6 = mutableMapOf("p" to 1, "q" to 2)
    m6.keys.clear()
    println(m6)

    // reads still behave like a normal Set/Collection
    val m7 = mutableMapOf("a" to 1, "b" to 2)
    println(m7.keys.sorted())
    println(m7.values.sum())
    println(m7.keys == setOf("a", "b"))
    println(m7.entries.map { "${it.key}:${it.value}" })

    // entries.iterator removal via remove on the entries set
    val m8 = mutableMapOf(1 to "a", 2 to "b", 3 to "c")
    val firstEntry = m8.entries.first { it.key == 2 }
    m8.entries.remove(firstEntry)
    println(m8)
}
