fun report(title: String, vararg items: Int, footer: String = "end"): String {
    return "$title [${items.joinToString(",")}] $footer"
}

fun main() {
    // pure positional, no named args at all: vararg fills, footer takes default
    println(report("T4", 6, 7, 8))
}
