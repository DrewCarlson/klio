// `final override` seals a method against any further override. A call through
// the declaring type is then monomorphic even though the class is `open`, so
// the lowerer resolves it statically — while a plain `override` stays virtual.
open class Shape {
    open fun name(): String = "shape"
    open fun sides(): Int = 0
}

open class Circle : Shape() {
    // Sealed: no subclass of Circle can change `name`.
    final override fun name(): String = "circle"
    // Still open: a subclass may refine it.
    override fun sides(): Int = 1
}

class Dot : Circle() {
    override fun sides(): Int = 0
}

class FinalOverloads {
    fun pick(value: Int): String = "int:$value"
    fun pick(value: String): String = "string:$value"
}

fun pickBoth(target: FinalOverloads): String =
    target.pick(1) + "/" + target.pick("x")

fun describe(shape: Shape): String = "${shape.name()} ${shape.sides()}"

fun main() {
    val shapes: List<Shape> = listOf(Shape(), Circle(), Dot())
    for (s in shapes) println(describe(s))
    println(pickBoth(FinalOverloads()))
}
