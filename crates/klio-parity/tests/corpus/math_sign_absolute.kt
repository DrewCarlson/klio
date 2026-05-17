// kotlin.math `sign` / `absoluteValue` extension properties on Int,
// Long, Double receivers. `Int.sign`/`Long.sign` yield Int;
// `Long.absoluteValue` stays Long; Double keeps Double.
import kotlin.math.absoluteValue
import kotlin.math.sign

fun main() {
    val l = -5_000_000_000L
    val i = -7
    val d = -3.5
    println(l.absoluteValue)
    println(i.absoluteValue)
    println(d.absoluteValue)
    println(l.sign)
    println(i.sign)
    println(0.sign)
    println(d.sign)
    println(12.sign)
}
