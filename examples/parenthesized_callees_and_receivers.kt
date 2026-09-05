// Syntax the corpus exercises that a reader rarely writes by hand: a
// parenthesized callee invoked on a receiver (`"O".(f)("K")` passes the
// receiver as the function's first argument), an extension property whose
// receiver is a function type in parentheses, `!!` written as two prefix
// negations, an empty loop body written as `;`, and a spread inside an
// annotation's arguments.
annotation class Tags(vararg val names: String)

val (Int.() -> String).twice: String
    get() = this(1) + this(2)

@Tags(*arrayOf("a", "b"), "c")
class Tagged

fun main() {
    val f: Int.() -> String = { "<$this>" }
    println(f.twice)
    println("O".(fun String.(y: String): String = this + y)("K"))
    val add: Int.(Int) -> Int = { this + it }
    println(1.(add)(2))
    val p = false
    if (!!!!!p) println("odd negations flip")
    if (!!!!p) println("even negations keep")
    var n = 0
    for (x in 1..5);
    for (x in 1..5) n += x
    println(n)
    println(Tagged::class.simpleName)
}
