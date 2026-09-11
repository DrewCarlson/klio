// Lambdas compiled to C. A lambda whose call site can see which body it holds
// is called directly, and what it captured is passed as leading arguments — no
// closure object is allocated and no dispatch happens. A lambda that escapes
// into a value is refused rather than silently losing its captures.
fun main() {
    val inc = { n: Int -> n + 1 }
    println(inc(5))
    println(inc(41))

    val base = 100
    val add = { n: Int -> n + base }
    println(add(5))

    val mul = { a: Int, b: Int -> a * b }
    println(mul(6, 7))

    val label = "n="
    val show = { n: Int -> label + n }
    println(show(3))

    var total = 0
    var i = 0
    while (i < 5) {
        total = total + inc(i)
        i = i + 1
    }
    println(total)

    // A `var` a lambda captures moves to a shared box, so both sides see the
    // writes the other makes.
    var count = 0
    val bump = { count = count + 1 }
    bump()
    bump()
    bump()
    println(count)

    var acc = ""
    val push = { s: String -> acc = acc + s }
    push("a")
    push("b")
    println(acc)
}
