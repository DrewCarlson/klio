// `x in lo..hi` is `(lo..hi).contains(x)`: the bounds are evaluated before
// the element, a range's own `contains` takes only its element type, and any
// other argument resolves to an extension, where a declaration in the
// program's own file outranks the stdlib's. Unsigned and full-width
// progressions keep their arithmetic in the element type's own domain.
val order = StringBuilder()
fun lo(v: Int): Int { order.append("L"); return v }
fun hi(v: Int): Int { order.append("H"); return v }
fun x(v: Int): Int { order.append("X"); return v }

operator fun ClosedRange<Int>.contains(value: Long): Boolean { order.append("E"); return value == 7L }
operator fun IntRange.contains(s: String): Boolean = s.length in this

fun main() {
    println(x(2) in lo(1)..hi(3))
    println(order)
    order.setLength(0)
    println(10L in 1..10)
    println(7L in 1..10)
    println(order)
    println("ab" in 1..3)
    println("abcd" in 1..3)
    val n: Int? = null
    println(n in 1..3)
    println(2u in 3u..1u)
    val r = 3u..1u
    println(r.contains(2u))
    val steps = mutableListOf<ULong>()
    for (i in 0uL..ULong.MAX_VALUE step Long.MAX_VALUE) steps += i
    println(steps)
    val wide = mutableListOf<Long>()
    for (i in Long.MIN_VALUE..Long.MAX_VALUE step Long.MAX_VALUE) wide += i
    println(wide)
    println(Long.MAX_VALUE in Long.MIN_VALUE..Long.MAX_VALUE step Long.MAX_VALUE)
    println(Long.MAX_VALUE - 1 in Long.MIN_VALUE..Long.MAX_VALUE step Long.MAX_VALUE)
}
