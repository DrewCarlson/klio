fun Map<String, Int>.sumVals2(): Int {
    val iterator = entries.iterator()
    var s = 0
    while (iterator.hasNext()) { s += iterator.next().value }
    return s
}
fun main() { println(mapOf("a" to 1, "b" to 2).sumVals2()) }
