fun greet(name: String, salutation: String = "Hi"): String = "$salutation, $name"

fun box(x: Int, y: Int, z: Int = 0): String = "($x, $y, $z)"

fun main() {
    // Out-of-order named args on a user function — slot by name.
    println(greet(salutation = "Hello", name = "Alice"))

    // Mix of positional and named, named first reordered, default kicks in.
    println(box(z = 9, x = 1, y = 2))
    println(box(1, y = 2))
    println(box(1, 2))

    // joinToString with reordered named args.
    val xs = listOf(1, 2, 3, 4)
    println(xs.joinToString(prefix = "[", postfix = "]", separator = " | "))
    println(xs.joinToString(postfix = "]", prefix = "[", separator = ", ", limit = 2))

    // Positional first, then named (the form kotlinc always accepts).
    println(xs.joinToString(", ", postfix = "]", prefix = "["))
}
