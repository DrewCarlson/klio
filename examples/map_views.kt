fun main() {
    val inventory = mutableMapOf("apple" to 3, "banana" to 0, "cherry" to 5, "date" to 0)

    // keys / values / entries are live views of the map.
    inventory.keys.removeAll(setOf("banana", "date"))
    println(inventory)

    val scores = mutableMapOf("alice" to 1, "bob" to 2, "carol" to 3)
    // MutableEntry.setValue writes through to the map.
    for (e in scores.entries) {
        e.setValue(e.value * 100)
    }
    println(scores)

    // values view removal drops the matching entry.
    val counts = mutableMapOf("x" to 1, "y" to 0, "z" to 2)
    counts.values.remove(0)
    println(counts)

    // retainAll on the key view keeps only the listed keys.
    val cfg = mutableMapOf("host" to "a", "port" to "b", "debug" to "c")
    cfg.keys.retainAll(setOf("host", "port"))
    println(cfg)

    // reads behave like ordinary collections.
    val m = mutableMapOf("a" to 1, "b" to 2, "c" to 3)
    println(m.keys.sorted())
    println(m.values.sum())
    println(m.entries.joinToString { "${it.key}=${it.value}" })
}
