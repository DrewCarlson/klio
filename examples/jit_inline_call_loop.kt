// Hot loop calling small pure functions each iteration. The loop JIT inlines a
// small single-block scalar callee directly into the native code (its registers
// remapped into an extended register space), so the calls become native
// arithmetic with no dispatch at all. Covers Int, Long, and Double results,
// numeric conversions inside the callee, and the same callee inlined at more than
// one site. Output must match with the JIT off (default) or on (KLIO_JIT=1).
fun sq(x: Int) = x * x
fun lmix(a: Int, b: Int) = a.toLong() * b.toLong()
fun scaled(x: Int) = x.toDouble() * 1.5

fun main() {
    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + sq(i) + sq(i + 1)) and 0x7fffffff
        i = i + 1
    }

    var l = 0L
    var j = 0
    while (j < 60000) {
        l = l + lmix(j, j + 1)
        j = j + 1
    }

    var d = 0.0
    var k = 0
    while (k < 60000) {
        d = d + scaled(k)
        k = k + 1
    }

    println("s=$s l=$l d=$d")
}
