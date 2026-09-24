// A defaulted parameter after a vararg fills only by name: every positional
// after the fixed prefix belongs to the vararg — on the static route, the
// value route, and a function reference adapted to a function type that
// spreads the vararg and drops the default.
fun report(title: String, vararg items: Int, footer: String = "end"): String =
    "$title [${items.joinToString(",")}] $footer"

fun main() {
    println(report("A", 1, 2, 3))
    println(report("D", 4, 5, footer = "z"))
    val f: (String, Int, Int, Int) -> String = ::report
    println(f("E", 7, 8, 9))
}
