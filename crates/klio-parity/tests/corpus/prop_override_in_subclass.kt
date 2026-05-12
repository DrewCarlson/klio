abstract class Shape {
    abstract val area: Int
    open val label: String = "shape"
}

class Square(val side: Int) : Shape() {
    override val area: Int = side * side
    override val label: String = "square"
}

class Rect(val w: Int, val h: Int) : Shape() {
    override val area: Int = w * h
}

fun main() {
    val s: Shape = Square(4)
    val r: Shape = Rect(3, 5)
    println(s.area)
    println(s.label)
    println(r.area)
    println(r.label)
}
