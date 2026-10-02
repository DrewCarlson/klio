// A map's entry is its node, as on the JVM: it reads the value the map holds
// while its key's node is in the map, keeps working after the map changes, and
// keeps the last value it had once its node is removed, even when the key comes
// back as a new node. A buildMap builder's entries fail fast instead.

fun main() {
    for ((label, map) in listOf(
        "HashMap" to hashMapOf("a" to 1, "b" to 2, "c" to 3),
        "LinkedHashMap" to linkedMapOf("a" to 1, "b" to 2, "c" to 3),
        "mutableMapOf" to mutableMapOf("a" to 1, "b" to 2, "c" to 3),
    )) {
        val b = map.entries.first { it.key == "b" }
        map["c"] = 30
        map["b"] = 20
        println("$label: ${b.key}=${b.value}")
        map["d"] = 4
        println("$label after a new key: $b ${b.hashCode()} ${b == mapOf("b" to 20).entries.first()}")
        println("$label setValue: ${b.setValue(21)} -> ${map["b"]}")
        map.remove("b")
        println("$label removed: ${b.key}=${b.value}")
        map["b"] = 99
        println("$label re-added: ${b.value}, setValue ${b.setValue(7)}, entry $b, map has ${map["b"]}")
    }

    // Entries collected, then the map cleared: each keeps its last value.
    val scores = mutableMapOf("x" to 1, "y" to 2)
    val kept = scores.entries.toList()
    scores["x"] = 10
    scores.clear()
    scores["x"] = 100
    println("kept $kept, map $scores")

    // Many removals: an entry finds its node however the others moved.
    val big = (0 until 1000).associateWith { it * 2 }.toMutableMap()
    val e700 = big.entries.first { it.key == 700 }
    for (k in 0 until 1000 step 2) if (k != 700) big.remove(k)
    big[700] = -1
    println("e700 = ${e700.value}, size ${big.size}")
    for (k in 1 until 600 step 2) big.remove(k)
    println("e700 = ${e700.value}, size ${big.size}")

    // A builder's entry fails fast after a structural change.
    val built = buildMap {
        put("a", 1)
        put("b", 2)
        val entry = entries.first { it.key == "b" }
        put("b", 20)
        println("builder entry ${entry.key}=${entry.value}")
        put("c", 3)
        try {
            println(entry.value)
        } catch (e: ConcurrentModificationException) {
            println("builder entry after a new key: ConcurrentModificationException")
        }
    }
    println(built)

}
