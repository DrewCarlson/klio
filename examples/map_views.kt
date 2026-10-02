// A map's `keys`, `values` and `entries` are views of it, made once and kept: a view held
// across changes to the map reads the map as it is now, and changes through a view, its
// iterator or its entries reach the map. A view holds no elements of its own.

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

    // A view held across changes reads the map as it is now.
    val held = linkedMapOf("a" to 1, "b" to 2)
    val ks = held.keys
    val vs = held.values
    val es = held.entries
    println("${held.keys === ks} ${held.values === vs} ${held.entries === es}")
    held["z"] = 26
    held.remove("a")
    held["b"] = 20
    println("$ks $vs $es ${"z" in ks} ${"a" in ks} ${20 in vs} ${ks.size}")
    ks.remove("b")
    println("$held $ks")
    held.putAll(mapOf("p" to 1, "q" to 2))
    val it = ks.iterator()
    while (it.hasNext()) if (it.next() == "p") it.remove()
    val vit = vs.iterator()
    while (vit.hasNext()) if (vit.next() == 26) vit.remove()
    println("$held $ks $vs $es")
    held.clear()
    println("${ks.isEmpty()} ${vs.isEmpty()} ${es.size} $ks")

    // A view is its own kind of collection: `keys` and `entries` are sets and compare as
    // sets, `values` is a collection that is neither a list nor a set.
    val kinds = linkedMapOf("a" to 1, "b" to 2)
    println("${kinds.keys is Set<*>} ${kinds.values is List<*>} ${kinds.values is Set<*>} ${kinds.entries is Set<*>}")
    println("${kinds.keys == setOf("b", "a")} ${kinds.values == listOf(1, 2)} ${kinds.values == kinds.values} ${kinds.entries == mapOf("a" to 1, "b" to 2).entries}")
    // `entries` finds and removes an entry of any kind by its key and value.
    val plain = object : Map.Entry<String, Int> {
        override val key = "a"
        override val value = 1
    }
    println("${kinds.entries.contains(plain as Map.Entry<*, *>)} ${(kinds.entries as Set<Any?>).contains("a")}")
    println("${kinds.entries.remove(plain as Map.Entry<*, *>)} $kinds")
    // Removing through an iterator over a few entries passes over none of the rest.
    val few = linkedMapOf(0 to "a", 1 to "b", 2 to "c", 3 to "d", 4 to "e")
    val seen = mutableListOf<Int>()
    val fit = few.keys.iterator()
    while (fit.hasNext()) {
        val k = fit.next()
        seen += k
        if (k % 2 == 0) fit.remove()
    }
    println("$seen $few")
    // A built map's views refuse every change, even one that would change nothing.
    val built = buildMap { put("x", 1) }
    for (attempt in listOf<() -> Any>(
        { (built.keys as MutableSet<String>).removeAll(emptyList()) },
        { (built.values as MutableCollection<Int>).remove(42) },
        { (built.entries as MutableSet<Map.Entry<String, Int>>).retainAll(emptyList()) },
    )) {
        println(runCatching(attempt).exceptionOrNull()?.let { it::class.simpleName })
    }

    // Membership through `keys` finds the key as the map does, at any size.
    val big = HashMap<Int, Int>()
    for (i in 0 until 50_000) big[i] = i * 2
    var hits = 0
    for (i in 0 until 100_000) if (i in big.keys) hits++
    println("hits $hits of ${big.keys.size}")
}
