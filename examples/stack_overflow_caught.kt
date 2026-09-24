// Recursion deeper than the stack allows throws `StackOverflowError`, which a
// program catches like any other throwable: its handler runs, the finally
// blocks it unwinds through run, and the program carries on.
fun deep(n: Int): Int = if (n == 0) 0 else 1 + deep(n - 1)

fun main() {
    println(deep(1_000))
    try {
        println(deep(1_000_000))
    } catch (e: StackOverflowError) {
        println("caught " + e::class.simpleName + " message=" + e.message)
    }
    var finallyRan = false
    try {
        try {
            deep(1_000_000)
        } finally {
            finallyRan = true
        }
    } catch (e: Throwable) {
        println("outer caught " + (e is StackOverflowError) + " finally=" + finallyRan)
    }
    println(deep(10))
}
