// A call with a `*spread` argument can only bind the spread to a `vararg`
// parameter, so overload selection must skip fixed-arity candidates.
// The zero-arg overloads here used to win the pick and the spread's
// elements were silently dropped.

fun counted(): Int = -1

fun counted(vararg xs: Int): Int = xs.size

fun <T> collected(): List<T> = emptyList()

fun <T> collected(vararg xs: T): List<T> = xs.toList()

fun main() {
    val ints = intArrayOf(1, 2, 3)
    println(counted(*ints))
    println(counted())
    val objs = arrayOf("a", "b")
    println(collected(*objs))
    println(collected<String>().size)
}
