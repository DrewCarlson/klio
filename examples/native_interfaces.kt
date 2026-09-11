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

// A superclass contributes its own fields, filled by the arguments this class
// passes up to its constructor.
open class Tagged(val tag: String) {
    open fun label(): String = tag
}

class Named(t: String, val n: Int) : Tagged(t) {
    override fun label(): String = tag + "#" + n
}

fun describe(s: Shape): String = s.name() + "=" + s.area()

fun labelOf(t: Tagged): String = t.label()

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

    val plain = Tagged("plain")
    val named = Named("item", 7)
    println(plain.label())
    println(named.label())
    println(labelOf(plain))
    println(labelOf(named))
    println(named.tag)
    println(named.n)
}
