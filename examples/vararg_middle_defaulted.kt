// A defaulted parameter after a vararg fills only by name: every positional
// after the fixed prefix belongs to the vararg — on the static route, the
// value route, and a function reference alike.
fun report(title: String, vararg items: Int, footer: String = "end"): String =
    "$title [${items.joinToString(",")}] $footer"

fun main() {
    println(report("A", 1, 2, 3))
    println(report("D", 4, 5, footer = "z"))
    val f = ::report
    println(f("E", 7, 8, 9))
}
