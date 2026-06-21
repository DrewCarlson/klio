// Recursive scalar functions with no enclosing loop: the whole-function JIT
// (opt-in, KLIO_JIT=1 KLIO_FUNC_JIT=1) compiles each body to native code and
// recurses natively through the call trampoline (no interpreter frame per call),
// while a div-by-zero still raises a catchable ArithmeticException via the deopt
// fallback. Output is identical with the JIT off (default), the loop JIT on
// (KLIO_JIT=1), or the function JIT also on (KLIO_FUNC_JIT=1).
fun fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)

fun fact(n: Long): Long = if (n <= 1L) 1L else n * fact(n - 1L)

fun ack(m: Int, n: Int): Int =
    if (m == 0) n + 1
    else if (n == 0) ack(m - 1, 1)
    else ack(m - 1, ack(m, n - 1))

fun isEven(n: Int): Boolean = if (n == 0) true else isOdd(n - 1)
fun isOdd(n: Int): Boolean = if (n == 0) false else isEven(n - 1)

fun safeDiv(n: Int): Int = if (n == 0) 100 / n else safeDiv(n - 1)

fun main() {
    println("fib(30)=${fib(30)}")
    println("fact(20)=${fact(20)}")
    println("ack(3,4)=${ack(3, 4)}")
    println("isEven(100)=${isEven(100)}")
    println("isOdd(101)=${isOdd(101)}")
    try {
        println(safeDiv(4))
    } catch (e: ArithmeticException) {
        println("caught: ${e.message}")
    }
}
