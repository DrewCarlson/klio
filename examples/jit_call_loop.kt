// A hot loop whose body calls a top-level function each iteration. The loop JIT
// trampolines the call: a native call site reboxes the scalar args, runs the
// callee through the interpreter, and reboxes the scalar result, so the loop's
// control flow and arithmetic stay native while the call dispatches normally.
// Covers an Int- and a Long-returning callee, a Double-returning callee, and a
// Unit-returning callee invoked only for its side effect. Output must match with
// the JIT off (default) or on (KLIO_JIT=1).
fun sq(x: Int): Int = x * x
fun addl(a: Long, b: Long): Long = a + b
fun half(x: Int): Double = x.toDouble() * 0.5

var sink = 0L
fun tally(x: Int) { sink = sink + x }

fun main() {
    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + sq(i)) and 0x7fffffff
        i = i + 1
    }

    var ls = 0L
    var j = 0
    while (j < 60000) {
        ls = addl(ls, j.toLong())
        j = j + 1
    }

    var d = 0.0
    var k = 0
    while (k < 60000) {
        d = d + half(k)
        k = k + 1
    }

    var m = 0
    while (m < 60000) {
        tally(m)
        m = m + 1
    }

    println("s=$s ls=$ls d=$d sink=$sink")
}
