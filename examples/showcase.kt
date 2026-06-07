// Exercises every piece of language functionality currently wired through
// the full lexer → parser → interpreter pipeline.
//
// Currently supported (Milestones 1–3):
//   * Top-level `fun main()`, user-defined functions (block + expression
//     body), `val` / `var` declarations.
//   * Default parameter values, recursion, mutual recursion.
//   * Integer literals (decimal, hex, binary, with `_` separators).
//   * Full arithmetic + comparison + logical operators with correct
//     precedence (Pratt parser).
//   * Unary `+` / `-` / `!`, prefix and postfix `++` / `--`.
//   * Parenthesized expressions.
//   * String literals and string templates (`$ident` and `${expr}`).
//   * `if` as an expression.
//   * `while` loops with `break` and `continue`.
//   * `for` loops over integer ranges (`..` and `..<`).
//   * `val` / `var` with `=`, `+=`, `-=`, `*=`, `/=`, `%=`.
//   * The built-in `println` intrinsic.
//
// Not yet wired through the interpreter (parses but errors at runtime):
//   * Member access on user types, indexing, classes, lambdas. These land
//     alongside the stdlib milestone.

fun main() {
    // ----- literals & arithmetic precedence -----
    println(1 + 2 * 3)         // 7
    println((1 + 2) * 3)       // 9
    println(10 - 4 - 2)        // 4
    println(-3 + +5)           // 2
    println(20 / 6)            // 3
    println(20 % 6)            // 2

    // ----- comparison & logical -----
    println(1 < 2 && 3 >= 3)   // true
    println(!(1 == 2) || false)// true
    println(1 == 1)            // true
    println("a" == "a")        // true

    // ----- val / var and assignment -----
    val a = 10
    var b = 5
    b = b + a
    b += 2
    b *= 2
    println(b)                 // 34

    // ----- if as expression -----
    val sign = if (b > 0) "positive" else if (b < 0) "negative" else "zero"
    println(sign)              // positive

    // ----- string templates -----
    val name = "world"
    println("hello, $name!")               // hello, world!
    println("answer = ${6 * 7}")           // answer = 42

    // ----- while loop with break -----
    var i = 0
    while (true) {
        if (i == 3) break
        println("i=$i")
        i = i + 1
    }
    // i=0 / i=1 / i=2

    // ----- while loop with continue -----
    var j = 0
    while (j < 5) {
        j = j + 1
        if (j == 3) continue
        println("j=$j")
    }
    // j=1 / j=2 / j=4 / j=5

    // ----- elvis -----
    val maybe: String = "ok"
    println(maybe)             // ok

    // ----- for loops over ranges -----
    for (k in 1..3) {
        println("k=$k")
    }
    // k=1 / k=2 / k=3

    for (k in 0..<3) {
        println("ex=$k")
    }
    // ex=0 / ex=1 / ex=2

    // ----- postfix and prefix increment -----
    var c = 10
    println(c++)               // 10 (returns old value)
    println(c)                 // 11
    println(++c)               // 12 (returns new value)

    // ----- user-defined functions, recursion -----
    println(square(7))         // 49
    println(fact(5))           // 120

    println("done.")
}

fun square(x: Int): Int = x * x

fun fact(n: Int): Int = if (n <= 1) 1 else n * fact(n - 1)
