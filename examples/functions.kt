// Focused example: user-defined functions, default arguments, recursion,
// mutual recursion, top-level properties, and local functions.

val tagline = "ktc M3 says hi"

fun greet(name: String = "world"): String = "hello, $name"

fun add(a: Int, b: Int): Int = a + b

fun describe(n: Int): String {
    if (n < 0) return "negative"
    if (n == 0) return "zero"
    return "positive"
}

// Recursion.
fun fact(n: Int): Int = if (n <= 1) 1 else n * fact(n - 1)

// Mutual recursion — forward-declared by the interpreter.
fun isEven(n: Int): Boolean = if (n == 0) true else isOdd(n - 1)
fun isOdd(n: Int): Boolean = if (n == 0) false else isEven(n - 1)

fun main() {
    println(tagline)              // ktc M3 says hi

    println(greet())              // hello, world
    println(greet("kotlin"))      // hello, kotlin

    println(add(2, 3))            // 5

    println(describe(-7))         // negative
    println(describe(0))          // zero
    println(describe(42))         // positive

    println(fact(6))              // 720

    println(isEven(10))           // true
    println(isOdd(10))            // false

    // Local functions close over the enclosing scope.
    val factor = 10
    fun scale(x: Int): Int = x * factor
    println(scale(4))             // 40
}
