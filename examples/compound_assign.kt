class Histogram {
    val counts = mutableMapOf<String, Int>()
    operator fun plusAssign(key: String) {
        counts[key] = (counts[key] ?: 0) + 1
    }
}

fun main() {
    val h = Histogram()
    val words = listOf("red", "blue", "red", "green", "blue", "red")
    for (w in words) {
        h += w
    }
    println(h.counts["red"])
    println(h.counts["blue"])
    println(h.counts["green"])

    val ledger = mutableListOf<Int>()
    ledger += 100
    ledger += 200
    ledger -= 100
    println(ledger)
}
