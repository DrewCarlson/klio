// A method calling sibling methods that branch: a value-returning helper
// built from `if`-returns (a clamp) and a `Unit` mutator whose body is also
// an `if`/`else`, both called from a third method on the same receiver.
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
