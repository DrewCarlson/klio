// Tour of M6b additions: exceptions, lambdas, scoping fns, String indexing,
// and the expanded stdlib intrinsic surface.

fun parseNumber(s: String): Int {
    return try {
        s.toInt()
    } catch (e: NumberFormatException) {
        -1
    }
}

fun main() {
    // ----- exceptions: throw + try/catch/finally -----
    try {
        throw IllegalArgumentException("nope")
    } catch (e: IllegalArgumentException) {
        println("caught: ${e.message}")
    } finally {
        println("finally ran")
    }

    // catch by supertype
    try {
        throw NullPointerException("oops")
    } catch (e: Throwable) {
        println("supertype caught: ${e.message}")
    }

    println(parseNumber("42"))
    println(parseNumber("not-a-number"))

    // ----- lambdas (explicit params, implicit `it`) -----
    val add = { a: Int, b: Int -> a + b }
    println(add(2, 3))

    val double = { x: Int -> x * 2 }
    println(double(7))

    // ----- scoping fns -----
    val n = 5
    println(n.let { it + 1 })             // 6 — let returns the lambda result; receiver is `it`
    println(n.also { println("seen $it") }) // prints "seen 5" then "5"; receiver is `it`

    // `apply` and `run` expose the receiver as `this`, not `it`.
    println("hi".apply { println("len=$length") })   // prints "len=2" then "hi"
    println("hi".run { length })                     // 2

    val pos = (-3).takeIf { it > 0 }
    val neg = (-3).takeUnless { it > 0 }
    println(pos)                          // null
    println(neg)                          // -3

    // `with(x) { ... }` also binds `this`.
    println(with(10) { this * this })     // 100

    // ----- String indexing + new members -----
    val word = "kotlin"
    println(word[0])                       // k
    println(word.substring(1, 4))          // otl
    println(word.uppercase())              // KOTLIN
    println(word.reversed())               // niltok
    println(word.repeat(2))                // kotlinkotlin
    println("hello".startsWith("he"))      // true
    println("hello".indexOf("ll"))         // 2
    println("hello".replace("l", "L"))     // heLLo

    // ----- Char inspection -----
    println('5'.isDigit())                 // true
    println('a'.isLetter())                // true
    println(' '.isWhitespace())            // true
    println('A'.code)                      // 65

    // ----- Int conversions + bitwise -----
    println(42.toString())                 // 42
    println(42.toDouble())                 // 42.0
    println((0xFF).and(0x0F))              // 15
    println((1).shl(4))                    // 16

    // ----- Double predicates + math expansion -----
    println(kotlin.math.sin(0.0))          // 0.0
    println(kotlin.math.floor(1.7))        // 1.0
    println(kotlin.math.ceil(1.2))         // 2.0
    println(kotlin.math.log10(100.0))      // 2.0
    println(kotlin.math.hypot(3.0, 4.0))   // 5.0

    println("done.")
}
