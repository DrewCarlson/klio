// A hot loop calling methods on a loop-invariant object each iteration. The loop
// JIT trampolines the member call: the receiver stays boxed in the frame's
// registers (read by the host, its class re-checked at loop entry) while scalar
// args and a scalar result move through slots. Covers an Int- and a Long-returning
// method and a Unit side-effecting method. Output must match with the JIT off
// (default) or on (KLIO_JIT=1).
class Calc(val k: Int) {
    var total = 0
    fun sq(x: Int): Int = x * x + k
    fun acc(a: Long, b: Int): Long = a + b
    fun tag(x: Int) { total = total + x }
}

fun main() {
    val c = Calc(7)

    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + c.sq(i)) and 0x7fffffff
        i = i + 1
    }

    var ls = 0L
    var j = 0
    while (j < 60000) {
        ls = c.acc(ls, j)
        j = j + 1
    }

    var m = 0
    while (m < 60000) {
        c.tag(m)
        m = m + 1
    }

    println("s=$s ls=$ls total=${c.total}")
}
