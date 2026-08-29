// A PRIVATE member-extension property on a companion (`private val
// Double.Companion.NegativeZero`) is visible only where its owner class is
// an executing receiver. The body that reads it runs on the fused walker
// with no frame, so the executing-function marker and the receiver-tower
// iterator must both surface the fused body (visibility + owner lookup).
class NegZeroBox {
    private val Float.Companion.NegativeZero: Float
        get() = Float.fromBits(0b1 shl 31)
    private val Double.Companion.NegativeZero: Double
        get() = Double.fromBits(0b1L shl 63)
    private fun same(a: Double, b: Double): Boolean = a == b
    fun t(): String {
        val f = Float.NegativeZero
        val d = Double.NegativeZero
        return "" + f.toRawBits() + "|" + d.toRawBits() + "|" + same(d, 0.0) + "|" + same(d, Double.NegativeZero)
    }
}
fun main() {
    println(NegZeroBox().t())
}
