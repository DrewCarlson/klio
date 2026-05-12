// Spec ch.9: lambda parameters can be destructured. `(a, b) ->` and the
// `_` placeholder both lower to a `componentN`-driven destructuring decl
// at the top of the lambda body. Per-slot type annotations are accepted.

fun main() {
    val pairs = listOf(1 to "a", 2 to "b", 3 to "c")
    pairs.forEach { (n, s) -> println("$n=$s") }
    pairs.forEach { (n, _) -> println(n) }
    pairs.forEach { (_, s) -> println(s) }
    pairs.forEach { (n: Int, s: String) -> println("$n-$s") }
}
