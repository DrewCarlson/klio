// Regression: a class with a same-named factory that fills a default parameter
// must resolve a single-argument call to the FACTORY, not the class constructor.
// `Packed(3f)` used to bind the value-class `Long` constructor (storing the
// Float), because the runtime factory pick required an exact argument count and
// skipped the defaulted `y`.
value class Packed(val bits: Long)

fun Packed(x: Float, y: Float = x): Packed =
    Packed((x.toInt().toLong() shl 32) or (y.toInt().toLong() and 0xFFFFFFFFL))

fun Packed.hi(): Int = (bits shr 32).toInt()

fun Packed.lo(): Int = bits.toInt()

fun main() {
    val p = Packed(3f) // factory; y defaults to x
    println("${p.hi()} ${p.lo()}")
    val q = Packed(5f, 7f)
    println("${q.hi()} ${q.lo()}")
}
