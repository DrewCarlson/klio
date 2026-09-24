// A method (`step`) delegating to another method (`blend`) that mixes Long
// addition, multiplication, division, remainder, and bitwise shifts with an
// Int-to-Long conversion (`k.toLong()`). Run across a large iteration range.
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
