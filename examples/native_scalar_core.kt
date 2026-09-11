// The subset `klio transpile --native` compiles to standalone C: scalar
// arithmetic, direct calls, loops and branches. The emitted file is the
// program — it loads no image and runs no interpreter — so this must print the
// same bytes whether it is interpreted or compiled.
fun mix(a: Int, b: Int): Int {
    var x = a * 3 + b
    x = x xor (a shl 2)
    return x % 1000003
}

fun fib(n: Int): Long = if (n < 2) n.toLong() else fib(n - 1) + fib(n - 2)

fun blend(a: Long, b: Double, pick: Boolean): Double {
    val s = if (pick) a.toDouble() + b else a.toDouble() - b
    return s * 2.0
}

fun main() {
    var i = 0
    var t = 0
    while (i < 200000) {
        t = mix(t, i)
        i = i + 1
    }
    println(t)

    var acc = 0L
    i = 0
    while (i < 24) {
        acc = acc + fib(i)
        i = i + 1
    }
    println(acc)

    println(blend(7L, 1.5, true))
    println(blend(7L, 1.5, false))
    println(3 / 2)
    println(-7 / 2)
    println(7L % 3L)
    println(1 shl 10)
    println(-8 ushr 1)
    println(-8 shr 1)
    println(2.5 > 1.0)
    println(!(1 == 2))
    println(17.0)
    println(0.1)
    println(1.0 / 3.0)
    println(1.0e20)
    println(1.0e-5)
    println(1.5f)
}
