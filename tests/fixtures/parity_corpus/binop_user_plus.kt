class Vec2(val x: Int, val y: Int) {
    operator fun plus(o: Vec2): Vec2 = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2): Vec2 = Vec2(x - o.x, y - o.y)
    operator fun times(k: Int): Vec2 = Vec2(x * k, y * k)
    override fun toString(): String = "($x, $y)"
}

fun main() {
    val a = Vec2(1, 2)
    val b = Vec2(3, 4)
    println(a + b)
    println(b - a)
    println(a * 5)
}
