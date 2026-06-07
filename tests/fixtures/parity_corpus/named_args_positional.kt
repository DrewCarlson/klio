fun greet(name: String, salutation: String = "Hi"): String = "$salutation, $name"

fun main() {
    // Named args in declaration order — parses and dispatches correctly today.
    println(greet(name = "Alice"))
    println(greet(name = "Bob", salutation = "Hello"))

    val xs = listOf(1, 2, 3, 4, 5)
    println(xs.joinToString(separator = ", ", prefix = "[", postfix = "]"))
    println(xs.joinToString(separator = " | "))
}
