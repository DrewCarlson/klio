// A lambda literal is an expression, so it can be invoked where it is
// written: `{ … }()` as a statement, and as the value of a named or
// positional argument (`f(b = { … }(), a = { … }())`), where the calls
// run in the order the arguments are written.
var trace = ""

fun test(a: String, b: String) = "$a$b"

fun main() {
    val x = { trace += "1"; "x" }()
    println(x)
    val r = test(b = { trace += "2"; "b" }(), a = { trace += "3"; "a" }())
    println(r)
    println(trace)
    println(listOf(1, 2, 3).map({ n: Int -> n * 2 }).joinToString())
    println({ s: String -> s.length }("four"))
    println(test({ "p" }(), { "q" }().uppercase()))
}
