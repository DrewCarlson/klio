import kotlin.properties.Delegates

class Counter {
    var hits: Int by Delegates.observable(0) { _, _, new -> println("hits=$new") }
    val label: String by lazy { "counter" }
    fun bump(by: Int = 1) { hits += by }
}

data class Point(val x: Int, val y: Int)

fun area(p: Point): Int = p.x * p.y
fun area(w: Int, h: Int): Int = w * h

fun Point.norm1(): Int = x + y

fun main() {
    val c = Counter()
    c.bump()
    c.bump(2)
    println(c.label.length)
    val grid = intArrayOf(1, 2, 3)
    grid[1] += 10
    for (n in grid) print(n)
    val (px, py) = Point(3, 4)
    println(area(Point(px, py)) + area(px, py))
    println(Point(1, 2).norm1())
    val text = with(StringBuilder()) {
        append("é")
        append(length)
        toString()
    }
    println(text)
}
