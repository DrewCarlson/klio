// Two things the whole-function tier used to refuse.
//
// `k.toLong()` on a scalar lowers to a VIRTUAL call, and the call-site pass
// treated it as a member call on a non-object receiver — which declined the
// whole method, so anything converting a number never compiled.
//
// `blend` also divides, so it can deopt. A direct call into a callee like that
// is still native: the caller tests the resume code the callee returns and
// re-runs the whole call interpreted when it is not RETURN. That answer is only
// correct because the callee writes no field before it can deopt.
//
// Output must match with the JIT off (--opt safe) or on, and with direct calls
// disabled (KLIO_FJ_DIRECT=0).
class Ratio(var num: Long, var den: Long) {
    fun blend(k: Int): Long {
        var r = num + k
        r = r * 31 + den
        r = r / (k.toLong() + 1)
        r = r xor (r shl 13)
        r = r * 7 + k
        r = r xor (r shl 7)
        r = r % (den + 3)
        r = r * 3 + num
        r = r xor (r shl 17)
        return r * 11 + den
    }

    fun step(k: Int): Long {
        return blend(k)
    }
}

fun main() {
    val q = Ratio(5L, 9L)
    var i = 0
    var t = 0L
    while (i < 120_000) {
        t = t xor q.step(i)
        i += 1
    }
    println("t=" + t)
}
