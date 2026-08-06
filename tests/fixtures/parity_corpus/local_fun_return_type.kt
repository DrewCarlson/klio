class Slot(val text: String) { fun size(): Int = text.length }

fun scan(s: String): Int {
    fun pick(at: Int): Slot? = if (at < s.length) Slot(s.substring(at, at + 1)) else null
    fun label(at: Int): Slot = Slot("<$at>")
    var total = 0
    pick(0)?.let { total += it.size() }
    pick(99)?.let { total += it.size() }
    total += label(2).size()
    return total
}

fun scanExt(s: String): String {
    fun String.wrapped(): Slot = Slot("[$this]")
    return s.wrapped().text
}

fun main() {
    println(scan("ab"))
    println(scanExt("q"))
}
