// A vararg before a trailing defaulted parameter, called purely
// positionally: every positional after the fixed prefix belongs to the
// vararg, since a defaulted parameter after a vararg is fillable only by
// name. A reference to the function is a value of type
// (String, IntArray, String) -> String: it takes the vararg as an array
// and the defaulted parameter as a plain one.
fun report(title: String, vararg items: Int, footer: String = "end"): String =
    "$title [${items.joinToString(",")}] $footer"
fun main() {
    println(report("A", 1, 2, 3))
    println(report("B", 1))
    println(report("C"))
    println(report("D", 4, 5, footer = "z"))
    val f = ::report
    println(f("E", intArrayOf(7, 8, 9), "end"))
}
