open class Shape
class Circle(val r: Int) : Shape()

class Canvas(val scale: Int) {
    fun area(s: Shape): Int {
        if (s !is Circle) throw IllegalArgumentException("only circles")
        return this.area(s)
    }

    fun area(s: Circle): Int = scale * s.r * s.r
}

fun main() {
    val s: Shape = Circle(3)
    println(Canvas(2).area(s))
    val t: Shape = Circle(5)
    if (t !is Circle || t.r < 0) throw IllegalStateException("no")
    println(t.r)
}
