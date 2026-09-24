// Writing scalar fields (Int, Long) of an object across a loop: each
// iteration reads the current field, computes a new value, and stores it
// back, on plain stored properties with no custom setter.
class Point(var x: Int, var y: Long)

fun main() {
    val p = Point(0, 0)
    var i = 0
    while (i < 200000) {
        p.x = p.x + i
        p.y = p.y + i.toLong()
        i = i + 1
    }
    println("x=${p.x} y=${p.y}")
}
