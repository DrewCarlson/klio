// Exercises the first slice of native Rust stdlib intrinsics wired through
// the interpreter in Milestone 6:
//
//   * kotlin.io.println          (implicit alias, lookup via ktc-stdlib)
//   * kotlin.math.* functions    (abs, min, max, sqrt)
//   * Double.pow(Int)            (extension; imported below)
//   * kotlin.math.* properties   (PI, E)
//   * kotlin.String.* members    (length, uppercase, lowercase, isEmpty,
//                                 isNotEmpty)
//   * kotlin.Int.* conversions   (toLong, toDouble, toString)

import kotlin.math.pow

fun main() {
    // Static dotted calls.
    println(kotlin.math.abs(-42))            // 42
    println(kotlin.math.max(3, 9))           // 9
    println(kotlin.math.min(3, 9))           // 3
    println(kotlin.math.sqrt(16.0))          // 4
    println(2.0.pow(10))                     // 1024.0

    // Static dotted properties.
    val pi = kotlin.math.PI
    val e = kotlin.math.E
    println(pi)                              // 3.141592653589793
    println(e)                               // 2.718281828459045

    // String members — property and method shape.
    val greeting = "Hello, World"
    println(greeting.length)                 // 12
    println(greeting.uppercase())            // HELLO, WORLD
    println(greeting.lowercase())            // hello, world
    println("".isEmpty())                    // true
    println(greeting.isNotEmpty())           // true

    // Method chaining — each step goes through the stdlib dispatcher.
    println("xyz".uppercase().lowercase())   // xyz

    // Int conversion members.
    val n = 7
    println(n.toString())                    // 7
    println(n.toDouble())                    // 7

    // Safe call on a non-null receiver still dispatches.
    val s: String = "ok"
    println(s?.length)                       // 2
}
