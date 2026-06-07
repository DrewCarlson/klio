fun main() {
    data class P(val x: Int, val y: Int)
    val a = P(1, 2)
    val b = P(1, 2)
    println(a)
    println(a == b)
    println(a.x + a.y)
}
