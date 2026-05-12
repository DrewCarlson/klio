data class Point(val x: Int, val y: Int)

fun main() {
    val a = Point(1, 2)
    val b = Point(1, 2)
    val c = Point(3, 4)
    println(a)
    println(a == b)
    println(a == c)
    println(a.toString())
    val moved = a.copy(y = 99)
    println(moved)
    println(a.component1())
    println(a.component2())
}
