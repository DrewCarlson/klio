fun sumDown(last: Int): Long {
    var acc = 0L
    for (i in last downTo 1) acc += i.toLong()
    return acc
}

fun charSpan(range: CharRange): String {
    val sb = StringBuilder()
    for (c in range) sb.append(c)
    return sb.toString()
}

fun main() {
    println(sumDown(5))
    println(charSpan('a'..'e'))
    var seen = 0
    for (i in 0 until 4) seen += i.countOneBits()
    println(seen)
    for (i in 6 downTo 0 step 2) print(i)
    println()
}
