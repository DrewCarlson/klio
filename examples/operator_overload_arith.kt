// Spec ch. 9: arithmetic / range / contains operator dispatch on user types.
// `+ - * / %` lower to `plus / minus / times / div / rem`; `..` and `..<` to
// `rangeTo` / `rangeUntil`; `in` and `!in` to `contains` on the right side.

class Vec2(val x: Int, val y: Int) {
    operator fun plus(o: Vec2): Vec2 = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2): Vec2 = Vec2(x - o.x, y - o.y)
    operator fun times(k: Int): Vec2 = Vec2(x * k, y * k)
    operator fun unaryMinus(): Vec2 = Vec2(-x, -y)
    override fun toString(): String = "($x, $y)"
}

class IntSet(val items: List<Int>) {
    operator fun contains(x: Int): Boolean {
        for (i in items) if (i == x) return true
        return false
    }
}

class Day(val n: Int) {
    operator fun rangeTo(end: Day): String = "Day(${n}..${end.n})"
}

// Extension form — still subject to the `operator` modifier requirement.
class Box(val n: Int) { override fun toString(): String = "Box($n)" }
operator fun Box.plus(other: Box): Box = Box(n + other.n)

fun main() {
    val a = Vec2(1, 2)
    val b = Vec2(3, 4)
    println(a + b)
    println(b - a)
    println(a * 5)
    println(-a)

    val s = IntSet(listOf(2, 4, 6))
    println(4 in s)
    println(5 in s)
    println(5 !in s)

    println(Day(1)..Day(7))

    println(Box(2) + Box(3))
}
