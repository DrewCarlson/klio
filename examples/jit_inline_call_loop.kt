// Small pure functions called in a loop: Int, Long, and Double results,
// numeric conversions inside the callee, and the same function called from
// more than one call site.
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
