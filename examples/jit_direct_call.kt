// A self-call helper too big for the splice still runs native: the caller calls
// straight into the callee's compiled code. The callee is a deopt-free method
// body over the same receiver, so the call needs no frame, no boxing and no
// host callback — it seeds the callee's argument slots and receiver field base
// inside the caller's own slot array and calls it. Output must match with the
// JIT off (--opt safe) or on, and with direct calls disabled (KLIO_FJ_DIRECT=0).
class Hash(var acc: Long, var salt: Int) {
    fun mix(n: Int): Long {
        var r = acc + n
        r = r * 31 + salt
        r = r xor (r shl 13)
        r = r * 7 + n
        r = r xor (r shl 7)
        r = r * 3 + salt
        r = r xor (r shl 17)
        r = r * 11 + n
        r = r xor (r shl 5)
        r = r * 13 + salt
        return r
    }

    fun step(n: Int): Long {
        acc = mix(n)
        return acc
    }
}

fun main() {
    val h = Hash(1L, 7)
    var i = 0
    var t = 0L
    while (i < 200_000) {
        t = t xor h.step(i)
        i += 1
    }
    println("t=" + t + " acc=" + h.acc)
}
