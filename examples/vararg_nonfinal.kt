// A `vararg` parameter before a trailing defaulted parameter, called purely
// positionally: the vararg consumes the middle positional args and the trailing
// parameter takes its default. Exercised on a top-level function, an inline
// function, and a member, plus the named-argument forms.

fun report(title: String, vararg items: Int, footer: String = "end"): String =
    "$title [${items.joinToString(",")}] $footer"

inline fun ireport(title: String, vararg items: Int, footer: String = "end"): String =
    "$title [${items.joinToString(",")}] $footer"

class R {
    fun report(title: String, vararg items: Int, footer: String = "end"): String =
        "$title [${items.joinToString(",")}] $footer"
}

fun main() {
    // top-level, all positional: items fills, footer defaults
    println(report("A", 1, 2, 3))
    println(report("B", 1))
    println(report("C"))
    // top-level, footer supplied by name (vararg still positional)
    println(report("D", 4, 5, footer = "z"))
    // inline
    println(ireport("E", 7, 8))
    println(ireport("F"))
    // member
    val r = R()
    println(r.report("G", 9))
    println(r.report("H"))
    println(r.report(title = "I", footer = "!"))
}
