// `is` / `as` against a typealias head behave as against the aliased
// target (`actual typealias TestResult = Unit` casts a Unit successfully).

typealias TR = Unit
typealias Text = String

fun main() {
    @Suppress("CAST_NEVER_SUCCEEDS")
    val u = Unit as TR
    println("cast: " + u)
    val s: Any = "abc"
    println(s is Text)
    println((s as Text).length)
}
