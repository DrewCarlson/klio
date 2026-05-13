// numeric fidelity: `1L..n` is a LongRange whose iteration variable
// is Long.

fun main() {
    for (i in 1L..3L) {
        println(i)
        println(i is Long)
    }
    val r = 1L..5L
    println(r is LongRange)
    println(r.first)
    println(r.last)
}
