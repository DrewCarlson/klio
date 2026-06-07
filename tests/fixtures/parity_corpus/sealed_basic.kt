sealed class Shape

class Circle(val radius: Int): Shape()
class Square(val side: Int): Shape()
class Rect(val w: Int, val h: Int): Shape()

fun area(s: Shape): Int = when (s) {
    is Circle -> s.radius * s.radius * 3
    is Square -> s.side * s.side
    is Rect -> s.w * s.h
    else -> 0
}

fun describe(s: Shape): String = when (s) {
    is Circle -> "circle(r=${s.radius})"
    is Square -> "square(s=${s.side})"
    is Rect -> "rect(${s.w}x${s.h})"
    else -> "?"
}

fun main() {
    val shapes: List<Shape> = listOf(Circle(2), Square(3), Rect(2, 5))
    for (s in shapes) {
        println("${describe(s)} -> ${area(s)}")
    }
}
