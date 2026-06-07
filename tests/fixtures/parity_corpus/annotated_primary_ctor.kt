// A primary constructor may carry annotations (and a visibility
// modifier), including a multi-line class header with a supertype.
// Annotations on a primary ctor are accepted (runtime no-ops here);
// a `@Ann` after a body-less class still annotates the next decl.
annotation class Tag(val name: String)
interface Shape { fun area(): Double }

class Circle
@Tag("geometry")
internal constructor(private val r: Double) :
    Shape {
    override fun area(): Double = 3.14 * r * r
}

@Tag("free")
fun describe(s: Shape): String = "area=${s.area()}"

fun main() {
    val c = Circle(2.0)
    println(c.area())
    println(describe(c))
}
