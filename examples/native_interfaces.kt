// Interfaces and virtual dispatch compiled to C. An interface contributes no
// fields, so implementing one changes nothing about a class's layout; which
// body a call reaches is the receiver's class, compared at run time against the
// class handles registered at startup.
interface Shape {
    fun area(): Int
    fun name(): String
}

class Rect(val w: Int, val h: Int) : Shape {
    override fun area(): Int = w * h
    override fun name(): String = "rect"
}

class Square(val s: Int) : Shape {
    override fun area(): Int = s * s
    override fun name(): String = "square"
}

fun describe(s: Shape): String = s.name() + "=" + s.area()

fun total(a: Shape, b: Shape): Int = a.area() + b.area()

fun main() {
    val r = Rect(3, 4)
    val q = Square(5)
    println(r.area())
    println(q.area())
    println(total(r, q))
    println(describe(r))
    println(describe(q))

    val shapes = listOf(r, q)
    var sum = 0
    var i = 0
    while (i < shapes.size) {
        sum = sum + 1
        i = i + 1
    }
    println(sum)
}
