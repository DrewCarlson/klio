// member function: vararg followed by trailing default, all positional
class R {
    fun report(title: String, vararg items: Int, footer: String = "end"): String {
        return "$title [${items.joinToString(",")}] $footer"
    }
}

fun main() {
    val r = R()
    println(r.report("A", 1, 2))
    println(r.report("B"))
    println(r.report(title = "C", footer = "z"))  // named -> works?
}
