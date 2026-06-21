// A hot outer loop whose body calls a function that itself runs a hot inner loop.
// The outer loop trampolines the call; the callee's own loop compiles too (its
// parameter's type is seeded from the live argument), so the inner loop runs
// natively while re-entered from inside the outer native loop. Output must match
// with the JIT off (default) or on (KLIO_JIT=1).
fun inner(n: Int): Int {
    var t = 0
    var a = 0
    while (a < 1000) {
        t = (t + a * n) and 0xffffff
        a = a + 1
    }
    return t
}

fun main() {
    var s = 0
    var i = 0
    while (i < 5000) {
        s = (s + inner(i)) and 0x7fffffff
        i = i + 1
    }
    println("s=$s")
}
