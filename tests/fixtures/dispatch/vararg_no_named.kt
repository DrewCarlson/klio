// vararg with a trailing DEFAULT param but NO named arg anywhere
fun report(title: String, vararg items: Int, footer: String = "end"): String {
    return "$title [${items.joinToString(",")}] $footer"
}

fun main() {
    println(report("A", 1))
    println(report("B", 1, 2))
    println(report("C"))
}
