// `let` binds the receiver as `it` and returns the lambda's result.
fun main() {
    val r = "abc".let { it.length }
    println(r)
}
