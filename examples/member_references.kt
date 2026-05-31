open class Shape(val name: String) {
    open fun area(): Double = 0.0
    val label: String get() = "shape:$name"
}

class Circle(val radius: Double) : Shape("circle") {
    override fun area(): Double = 3.14 * radius * radius
}

fun describe(s: Shape): String = "${s.name}=${s.area()}"

fun main() {
    val c = Circle(2.0)

    // Bound references: property, getter-backed property, and method.
    val radiusRef = c::radius
    val labelRef = c::label
    val areaRef = c::area
    println(radiusRef())
    println(labelRef())
    println(areaRef())

    val shapes = listOf(Circle(1.0), Circle(2.0), Circle(3.0))

    // Unbound references used as transforms.
    println(shapes.map(Circle::radius))
    println(shapes.map(Shape::name))
    println(shapes.map(Shape::label))
    println(shapes.map(Shape::area))

    // Top-level function reference.
    println(shapes.map(::describe))
}
