// Methods called on the same object each iteration of a loop: an
// Int-returning method, a Long-returning method, and a Unit method with a
// side effect on a field.
class Calc(val k: Int) {
    var total = 0
    fun sq(x: Int): Int = x * x + k
    fun acc(a: Long, b: Int): Long = a + b
    fun tag(x: Int) { total = total + x }
}

fun main() {
    val c = Calc(7)

    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + c.sq(i)) and 0x7fffffff
        i = i + 1
    }

    var ls = 0L
    var j = 0
    while (j < 60000) {
        ls = c.acc(ls, j)
        j = j + 1
    }

    var m = 0
    while (m < 60000) {
        c.tag(m)
        m = m + 1
    }

    println("s=$s ls=$ls total=${c.total}")
}
