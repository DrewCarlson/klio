// The accessor-delegation shape: a method calling sibling methods that READ and
// WRITE `this`-fields. The splice turns those field ops into the caller's own
// native field sites — the receiver is the caller's `this`, so they ride the same
// entry field-base and the method still compiles frameless. A mutator returning
// `Unit` counts too. Output must match with the JIT off (--opt safe) or on, and
// with the splice disabled (KLIO_FJ_SELF_INLINE=0).
class Grid(var w: Int, var h: Int) {
    var touched = 0
    fun area(): Int = w * h
    fun widen(k: Int) { w = w + k }
    fun note() { touched = touched + 1 }
    fun step(k: Int): Int {
        widen(k)
        note()
        return area()
    }
}

fun main() {
    val g = Grid(2, 3)
    var i = 0
    var t = 0
    while (i < 120_000) {
        t = (t + g.step(if (i % 1000 == 0) 1 else 0)) % 1000003
        i += 1
    }
    println("t=" + t + " w=" + g.w + " touched=" + g.touched)
}
