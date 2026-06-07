// `plus` lacks the `operator` modifier but is reached through `a + b`.
// Expect a T0087 warning diagnostic from the type checker.

class Vec2(val x: Int, val y: Int) {
    fun plus(o: Vec2): Vec2 = Vec2(x + o.x, y + o.y)
}

fun main() {
    val a = Vec2(1, 2)
    val b = Vec2(3, 4)
    val sum = a + b
    println(sum.x)
}
