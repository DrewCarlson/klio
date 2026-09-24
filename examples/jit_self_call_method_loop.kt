// A method calling a sibling method on the same receiver (`this.mul(...)`,
// written bare) inside a loop, then reading the resulting fields back
// afterward.
class Vec(var x: Int, var y: Int) {
    fun mul(a: Int, b: Int): Int = a * b
    fun scale(k: Int) { x = mul(x, k); y = mul(y, k) }
    fun sum(): Int = x + y
}

fun main() {
    val v = Vec(1, 2)
    var i = 0
    while (i < 200_000) { v.scale(1); i += 1 }
    println("sum=" + v.sum())
}
