// Kotlin's unsigned integers compiled to C. They are value classes over the
// signed widths, so they hold the same bits and constructing one — which is
// what `n.toUInt()` does — reinterprets rather than allocates. Only
// comparison, division and the right shift read them differently, which is
// exactly what C's unsigned types give. A program holding one renders it
// through the runtime, because an unsigned value prints as unsigned.
fun main() {
    val a: UInt = 4000000000u
    val b: UInt = 5u
    println(a)
    println(a + b)
    println(a / b)
    println(a > b)
    val c: ULong = 18000000000000000000uL
    println(c)
    println(c / 3uL)
    var s: UInt = 0u
    for (i in 1..4) s = s + i.toUInt()
    println(s)
}
