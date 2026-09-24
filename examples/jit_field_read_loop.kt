// Reading scalar fields (Int, Long, Double) of an object across a loop, plus
// a field mutated through a method call and read back the same iteration.
class Point(var x: Int, var y: Long, val scale: Double)

class Counter(var n: Int) {
    fun bump() { n = n + 1 }
}

fun main() {
    val p = Point(3, 100L, 2.5)

    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + p.x) and 0x7fffffff
        i = i + 1
    }

    var ls = 0L
    var j = 0
    while (j < 60000) {
        ls = ls + p.y
        j = j + 1
    }

    var d = 0.0
    var k = 0
    while (k < 60000) {
        d = d + p.scale
        k = k + 1
    }

    // A field mutated through a method, then read back the same iteration.
    val c = Counter(0)
    var sum = 0
    var m = 0
    while (m < 60000) {
        c.bump()
        sum = (sum + c.n) and 0x7fffffff
        m = m + 1
    }

    println("s=$s ls=$ls d=$d n=${c.n} sum=$sum")
}
