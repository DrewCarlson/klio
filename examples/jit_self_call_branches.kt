// A self-call helper that BRANCHES: the splice covers the callee's whole block
// graph, so an `if`/`when` helper inlines as well as a straight-line one. Both
// a value-returning helper and a `Unit` mutator are exercised. Output must match
// with the JIT off (--opt safe) or on, and with the splice disabled
// (KLIO_FJ_SELF_INLINE=0).
class Window(var lo: Int, var hi: Int) {
    fun clamp(v: Int): Int {
        if (v < lo) return lo
        if (v > hi) return hi
        return v
    }

    fun widen(k: Int) {
        if (k > 0) hi = hi + 1 else lo = lo - 1
    }

    fun step(i: Int): Int {
        widen(i - 2)
        return clamp(i - 3000)
    }
}

fun main() {
    val w = Window(-100, 100)
    var s = 0L
    var i = 0
    while (i < 200_000) {
        s += w.step(i).toLong()
        i += 1
    }
    println("s=" + s + " lo=" + w.lo + " hi=" + w.hi)
}
