// Recursive scalar functions with no enclosing loop: `fib`, `fact`, a
// two-argument Ackermann function, and mutually recursive `isEven`/`isOdd`.
// A recursive function that eventually divides by zero raises a catchable
// `ArithmeticException`.
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
    // Deliberately modest arguments: this is a correctness/demonstration program
    // run through the arena-backed corpus harness (which does not reclaim per-call
    // frames mid-run), so the call counts are kept small. The speedup is measured
    // separately on larger inputs.
    println("fib(20)=${fib(20)}")
    println("fact(20)=${fact(20)}")
    println("ack(3,3)=${ack(3, 3)}")
    println("isEven(100)=${isEven(100)}")
    println("isOdd(101)=${isOdd(101)}")
    try {
        println(safeDiv(4))
    } catch (e: ArithmeticException) {
        println("caught: ${e.message}")
    }
}
