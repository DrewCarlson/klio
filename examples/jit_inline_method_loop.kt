// Hot loop calling a small method on a loop-invariant object each iteration. The
// loop JIT inlines the method body directly into the native loop: scalar arithmetic
// runs native, and the method's `this`-field reads/writes become direct field
// accesses on the receiver — eliminating the per-iteration method dispatch. A
// polymorphic (per-iteration) receiver would instead keep dynamic dispatch. Output
// must match with the JIT off (default) or on (KLIO_JIT=1).
class Point(var x: Int, var y: Long) {
    fun step(d: Int) { x = x + d; y = y + x.toLong() }
}

fun main() {
    val p = Point(0, 0)
    var i = 0
    while (i < 200000) {
        p.step(i)
        i = i + 1
    }
    println("x=${p.x} y=${p.y}")
}
