open class Shape
class Circle : Shape()
class Square : Shape()

fun main() {
    val mixed: List<Any> = listOf(1, "two", 3, "four", 5.0, true, 6)
    println(mixed.filterIsInstance<Int>())
    println(mixed.filterIsInstance<String>())
    println(mixed.filterIsInstance<Number>())
    println(mixed.filterIsInstance<Boolean>())

    val shapes: List<Shape> = listOf(Circle(), Square(), Circle(), Circle())
    println(shapes.filterIsInstance<Circle>().size)
    println(shapes.filterIsInstance<Square>().size)
    println(shapes.filterIsInstance<Shape>().size)

    val arr: Array<Any> = arrayOf("a", 1, "b", 2, "c")
    println(arr.filterIsInstance<String>())

    val withNulls = listOf(1, null, "x", null, 2)
    println(withNulls.filterIsInstance<Int>())
    println(withNulls.filterIsInstance<String>())
}
