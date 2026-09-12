// A list of objects compiled to C. The emitter carries what a container holds,
// not just the machine type of its elements: a literal's elements answer the
// class they share, and a declared `List<Shape>` says so outright. That is what
// lets a member call on a loop variable dispatch.
open class Shape(val label: String) {
    open fun area(): Int = 0
}

class Square(val side: Int) : Shape("square") {
    override fun area(): Int = side * side
}

class Rect(val w: Int, val h: Int) : Shape("rect") {
    override fun area(): Int = w * h
}

fun describe(shapes: List<Shape>): Int {
    var total = 0
    for (s in shapes) total = total + s.area()
    return total
}

fun main() {
    val shapes = listOf(Square(2), Rect(2, 3), Shape("plain"))
    for (s in shapes) println(s.label + " " + s.area())
    println(shapes[0].area())
    println(describe(shapes))
}
