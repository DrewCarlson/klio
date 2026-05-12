// Integer / by zero throws kotlin.ArithmeticException with message "/ by zero".
fun main() {
    try {
        println(1 / 0)
    } catch (e: ArithmeticException) {
        println("caught: ${e.message}")
    }
}
