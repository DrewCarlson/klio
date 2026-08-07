// Inside an inline extension's spliced body, a bare iterator() must type
// from the WINDOW receiver (List<String>, projected to the declared
// Iterable head with its argument intact) — a non-exact top-level pick
// handed a Map-family iterator's Iterator<Entry> to this splice and every
// next() after it typed Entry. The spliced selector's parameter types from
// its CALL-shaped argument (selector(iterator.next())).
fun main() {
    val data = listOf("abca", "bcaa", "cabb")
    val result = data.minOfWith(compareBy { it.reversed() }) { it.take(3) }
    val resultMax = data.maxOfWith(compareBy { it.reversed() }) { it.take(3) }
    println(result)
    println(resultMax)
    println(listOf("x").minOfWith(naturalOrder()) { it })
}
