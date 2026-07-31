// A classifier whose values are host-represented (`Iterator`, `StringBuilder`,
// `ArrayList`, `Int`) still binds its members to a virtual slot. The slot is
// resolved against an interpreted receiver's own class, so a user subtype's
// override wins, and it falls back to the member's name for a host-backed
// value, which has no vtable to index.
class Countdown(private var n: Int) : Iterator<Int> {
    override fun hasNext(): Boolean = n > 0
    override fun next(): Int {
        n--
        return n
    }
}

// The receiver's static type is the interface, so this is one binding serving
// both a host-backed iterator and an interpreted one.
fun drain(it: Iterator<Int>): String {
    val sb = StringBuilder()
    while (it.hasNext()) {
        sb.append(it.next())
        sb.append(",")
    }
    return sb.toString()
}

fun main() {
    println(drain(listOf(10, 20, 30).iterator()))
    println(drain(Countdown(3)))

    val sb = StringBuilder()
    sb.append("a")
    sb.append(1)
    sb.append(true)
    println(sb.toString())

    val al = ArrayList<String>()
    al.add("x")
    al.add("y")
    al.add(0, "w")
    println(al.joinToString("|"))
    println(al.size)

    println(42.toLong() + 1L)
    println(7.toByte().toInt())
    println((3.5).toFloat().toDouble() > 3.0)
}
