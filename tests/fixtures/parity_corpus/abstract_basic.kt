abstract class Shape {
    abstract fun area(): Double
    fun describe(): String = "area=${area()}"
}

class Circle(val radius: Double) : Shape() {
    override fun area(): Double = 3.14 * radius * radius
}

class Square(val side: Double) : Shape() {
    override fun area(): Double = side * side
}

fun main() {
    val shapes: List<Shape> = listOf(Circle(2.0), Square(3.0))
    for (s in shapes) {
        println(s.describe())
    }
}
