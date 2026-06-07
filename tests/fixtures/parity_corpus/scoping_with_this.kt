// Top-level `with(receiver) { ... }` binds the receiver as `this`.
fun main() {
    val r = with(10) { this * this }
    println(r)
}
