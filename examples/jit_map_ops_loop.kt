// Hot loops storing into and loading from a loop-invariant map. The loop JIT
// trampolines `map[key] = value` and `map[key]` (the latter yielding a nullable
// scalar, folded with `?:`), keeping the map boxed in the register array while the
// keys, the Elvis default, and the accumulation run natively. A missing key reads
// back as null. Output must match with the JIT off (default) or on (KLIO_JIT=1).
fun main() {
    val m = HashMap<Int, Int>()
    var i = 0
    while (i < 4000) {
        m[i] = i * 2
        i = i + 1
    }

    var s = 0L
    var j = 0
    while (j < 8000) { // half the keys are absent -> null -> Elvis default
        s = s + (m[j] ?: -1).toLong()
        j = j + 1
    }

    println(s)
}
