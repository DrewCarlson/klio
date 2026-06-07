// A top-level factory function sharing its name with a sealed class
// wins for positional and named calls (the sealed class cannot be
// constructed); trailing defaulted params are filled.
sealed class Shape {
    abstract val area: Int
}
class Box(val side: Int) : Shape() {
    override val area: Int get() = side * side
}
fun Shape(side: Int = 1, scale: Int = 1): Shape = Box(side * scale)

fun main() {
    println(Shape(side = 3).area)
    println(Shape(2, 5).area)
    println(Shape().area)
    println(Shape(scale = 4).area)
}
