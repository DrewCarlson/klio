// A zero-argument `println()` inside a receiver scope is the top-level
// kotlin.io function: the implicit receiver must not become its argument.
class Box
fun main() {
    with(Box()) {
        print("a")
        println()
        print("b")
        println()
    }
}
