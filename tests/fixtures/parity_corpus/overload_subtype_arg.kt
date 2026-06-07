// Overload resolution must match an argument against a parameter
// declared as one of its supertypes/interfaces: `use(Sub)` picks
// `handle(Base)` over the unrelated 1-arg `handle(String)` overload,
// and a subclass instance satisfies an interface-typed parameter.
interface Shape {
    fun area(): Int
}

open class Base(val tag: String)

class Sub(tag: String, val extra: Int) : Base(tag)

class Circle(val r: Int) : Shape {
    override fun area(): Int = r * r * 3
}

class Sink {
    fun handle(b: Base): String = "base:${b.tag}"
    fun handle(s: String): String = "string:$s"
    fun handle(sh: Shape): String = "shape:${sh.area()}"
}

fun main() {
    val sink = Sink()
    println(sink.handle(Sub("s", 9)))
    println(sink.handle(Base("b")))
    println(sink.handle("x"))
    println(sink.handle(Circle(4)))
}
