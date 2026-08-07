fun mixedHash(c: Collection<*>): Int {
    var h = 1
    for (e in c) h = 31 * h + (e?.hashCode() ?: 0)
    return h
}

fun render(c: Collection<*>): String {
    val sb = StringBuilder()
    for (e in c) sb.append(e.toString()).append(";")
    return sb.toString()
}

fun keysOf(m: Map<*, *>): Int {
    var n = 0
    for (k in m.keys) if (k != null) n += 1
    return n
}

fun main() {
    println(mixedHash(listOf(1, "a")) != 0)
    println(render(listOf(1, "a", null)))
    println(keysOf(mapOf("x" to 1, "y" to 2)))
}
