// A method on an object called repeatedly in a loop: the method reads and
// writes the receiver's `this`-fields (Int and Long), and the final field
// values are read back after the loop.
class Point(var x: Int, var y: Long) {
    fun step(d: Int) { x = x + d; y = y + x.toLong() }
}

fun main() {
    val p = Point(0, 0)
    var i = 0
    while (i < 200000) {
        p.step(i)
        i = i + 1
    }
    println("x=${p.x} y=${p.y}")
}
