// Runtime overload dispatch over a suspend-vs-plain pair (verified against
// kotlinc-jvm 2.3.21 and kotlinc-native 2.3.10, which agree). A plain
// function-typed value binds the plain overload (no suspend conversion for
// values); a `suspend { … }` literal is a suspend function value and binds
// the suspend overload.
fun take(f: suspend () -> String): String = "take(suspend)"
fun take(f: () -> String): String = "take(plain)"

fun main() {
    val g: () -> String = { "x" }
    println(take(g))
    println(take(suspend { "y" }))
}
