data class Point(val x: Int, val y: Int)

fun main() {
    val p = Point(3, 4)
    val (x, y) = p
    println(x)
    println(y)
    println(x + y)
}
