// `rangeTo` and `rangeUntil` called by name on Int, Long, and Char build
// the same primitive ranges the `..` and `..<` operators do (IntRange,
// LongRange, CharRange), so they iterate, report their bounds, and are
// the range types they claim to be.
fun main() {
    for (i in 0.rangeTo(3)) print(i)
    println()
    for (i in 0.rangeUntil(3)) print(i)
    println()
    println(0.rangeTo(3) is IntRange)
    println(0.rangeTo(3) == 0..3)
    val longs = 1L.rangeTo(3L)
    println(longs)
    println(longs.last)
    println('a'.rangeTo('c').toList())
    println(5.rangeTo(1).isEmpty())
    println(10.rangeTo(12).sum())
}
