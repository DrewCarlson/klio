// `run` binds the receiver as `this` and returns the lambda's result.
fun main() {
    val r = "abc".run { length }
    println(r)
}
