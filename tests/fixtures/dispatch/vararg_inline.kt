// inline function: vararg followed by trailing default, all positional
inline fun report(title: String, vararg items: Int, footer: String = "end"): String {
    return "$title [${items.joinToString(",")}] $footer"
}

fun main() {
    println(report("A", 1, 2))
    println(report("B"))
}
