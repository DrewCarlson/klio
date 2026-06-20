// Float/Double -> Int/Long conversions in a hot loop, including the edge cases
// Kotlin clamps: NaN -> 0, overflow -> Int/Long.MIN_VALUE/MAX_VALUE, else
// truncate toward zero. The loop JIT compiles these (cvtt*2si + clamp); output is
// identical with the JIT off or on.
fun main() {
    val xs = DoubleArray(10)
    xs[0] = 3.9; xs[1] = -3.9
    xs[2] = 1.0 / 0.0; xs[3] = -1.0 / 0.0; xs[4] = 0.0 / 0.0
    xs[5] = 3.0e9; xs[6] = -3.0e9          // beyond Int range
    xs[7] = 9.3e18; xs[8] = -9.3e18        // beyond Long range
    xs[9] = 42.5
    val n = 10
    var sumI = 0L
    var sumL = 0L
    var r = 0
    while (r < 100) {
        var i = 0
        while (i < n) {
            sumI = sumI + xs[i].toInt().toLong()
            sumL = sumL + xs[i].toLong()
            i = i + 1
        }
        r = r + 1
    }
    println("sumI=$sumI sumL=$sumL")
}
