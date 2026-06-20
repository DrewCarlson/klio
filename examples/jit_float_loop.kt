// Hot Float (f32) arithmetic, comparison, and Int→Float conversion over a
// FloatArray. The loop JIT compiles these to single-precision SSE2 (addss/mulss/
// ucomiss/cvtsi2ss …); output is identical with the JIT off or on.
fun main() {
    val n = 2000
    val a = FloatArray(n)
    var x = 0.0f
    var i = 0
    while (i < n) {
        a[i] = x
        x = x + 0.5f
        i = i + 1
    }
    var sum = 0.0f
    var big = 0
    i = 0
    while (i < n) {
        sum = sum + a[i] * 2.0f - 1.0f
        if (a[i] > 500.0f) big = big + 1
        i = i + 1
    }
    var conv = 0.0f
    i = 0
    while (i < n) {
        conv = conv + i.toFloat() * 0.25f
        i = i + 1
    }
    println("sum=$sum big=$big conv=$conv")
}
