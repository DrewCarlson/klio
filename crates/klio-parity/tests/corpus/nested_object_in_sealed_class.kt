sealed class Shape {
    data class Circle(val r: Double) : Shape()
    data class Rectangle(val w: Double, val h: Double) : Shape()
    object Empty : Shape()
}

fun Shape.label(): String = when (this) {
    is Shape.Circle -> "circle:$r"
    is Shape.Rectangle -> "rect:${w}x${h}"
    Shape.Empty -> "empty"
}

fun main() {
    val shapes: List<Shape> = listOf(Shape.Circle(2.0), Shape.Rectangle(3.0, 4.0), Shape.Empty)
    for (s in shapes) println(s.label())
}
