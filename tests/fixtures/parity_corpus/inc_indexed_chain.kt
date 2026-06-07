var calls = 0
fun idx(): Int { calls = calls + 1; return 0 }

fun main() {
    val xs = intArrayOf(100, 200)
    xs[idx()]++
    println(xs[0])
    println(calls)

    val ys = intArrayOf(10, 20, 30)
    println(ys[1]++)
    println(ys[1])
    println(++ys[2])
    println(ys[2])
}
