open class Shape
class Circle : Shape()
class Square : Shape()

class Box {
    constructor(a: Int) { tag = "i$a" }
    constructor(a: String) { tag = "s$a" }
    constructor(a: Shape) { tag = "shape" }
    constructor(a: Circle) { tag = "circle" }
    var tag: String = ""
}

class Held(a: Shape) {
    var tag: String = "shape"
    constructor(a: Circle) : this(a as Shape) { tag = "circle" }
}

fun main() {
    val c = Circle()
    val s: Shape = c
    println(listOf(Box(1).tag, Box("x").tag, Box(c).tag, Box(s).tag, Box(Square()).tag).joinToString(","))
    println(listOf(Held(c).tag, Held(s).tag, Held(Square()).tag).joinToString(","))
}
