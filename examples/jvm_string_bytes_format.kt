// The JVM String surface the common stdlib does not declare: a string's
// UTF-8 bytes and back, `format` on a format string or through
// `String.format`, and a map sorted by its keys.

fun main() {
    val bytes = "hé!".toByteArray()
    println(bytes.size)
    println(String(bytes))
    println(String(bytes, 0, 2))
    println(String(bytes, 3, 1))
    println(bytes.decodeToString())

    println("x=%d, y=%s".format(7, "seven"))
    println(String.format("%05d|%-4s|%x|%.2f", 42, "ab", 255, 1.5))

    val m = mapOf("b" to 2, "c" to 3, "a" to 1)
    println(m.toSortedMap())
    println(m.toSortedMap(compareByDescending { it }))
    println(mapOf("B" to 1, "b" to 2, "a" to 3).toSortedMap(String.CASE_INSENSITIVE_ORDER))
}
