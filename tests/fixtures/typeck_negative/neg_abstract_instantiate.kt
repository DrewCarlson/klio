abstract class Shape {
    abstract fun area(): Int
}

class Square : Shape()

fun main() {
    println(Square().area())
}
