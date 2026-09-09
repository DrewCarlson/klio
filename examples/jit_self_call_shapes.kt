// Self-call shapes the whole-function tier splices: `this.helper(...)` lowers
// to a static call with the receiver moved into arg 0, and inlining a callee
// that never touches `this` makes both the move and the call disappear — so
// the method still compiles frameless. Covers Int/Long/Double/Boolean callees,
// a nested self-call, one feeding a field write, and one in a branch condition.
// Output must match with the JIT off (--opt safe) or on, and with the splice
// disabled (KLIO_FJ_SELF_INLINE=0).
class Shapes(var acc: Long, var n: Int) {
    fun addI(a: Int, b: Int): Int = a + b
    fun mulL(a: Long, b: Long): Long = a * b
    fun scaleD(a: Double): Double = a * 2.0
    fun neg(a: Int): Int = -a
    fun cmp(a: Int, b: Int): Boolean = a > b

    fun step(k: Int) {
        n = addI(n, k)
        acc = mulL(acc + 1L, 2L) % 1000003L
        if (cmp(n, 100)) { n = neg(n) }
    }

    fun nested(k: Int): Int = addI(addI(k, 1), neg(k))
    fun viaDouble(): Int = scaleD(1.5).toInt()
}

fun main() {
    val s = Shapes(1L, 0)
    var i = 0
    while (i < 60_000) {
        s.step(1)
        i += 1
    }
    var t = 0
    var j = 0
    while (j < 40_000) { t += s.nested(j % 7) + s.viaDouble(); j += 1 }
    println("acc=" + s.acc + " n=" + s.n + " t=" + t)
}
