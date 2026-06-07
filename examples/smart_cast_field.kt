// M23 smart-cast narrowing for `val` instance fields. After
// `if (w.shape is Circle)` the type checker narrows `w.shape` to `Circle`
// inside the branch, so `w.shape.radius` resolves through `Circle`'s
// member table without an explicit cast.

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
