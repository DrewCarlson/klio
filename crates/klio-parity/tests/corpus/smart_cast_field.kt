// Smart-cast narrowing for a `val` member chain: `w.shape is Circle` lets
// the body read `w.shape.radius` without an explicit cast.

open class Shape
class Circle(val radius: Int): Shape()
class Square(val side: Int): Shape()

class Wrapper(val shape: Shape)

fun area(w: Wrapper): Int {
    if (w.shape is Circle) {
        return w.shape.radius * w.shape.radius
    }
    if (w.shape is Square) {
        return w.shape.side * w.shape.side
    }
    return 0
}

fun main() {
    println(area(Wrapper(Circle(3))))
    println(area(Wrapper(Square(4))))
    println(area(Wrapper(Shape())))
}
