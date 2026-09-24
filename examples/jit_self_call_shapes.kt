// Self-call shapes (`this.helper(...)`, written bare) covering Int, Long,
// Double, and Boolean-returning helpers: a nested self-call, one feeding a
// field write, and one used as a branch condition.
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
