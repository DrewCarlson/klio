// An interface with several same-named top-level factory functions: a call
// must reach the factory whose parameter types fit the arguments, not merely
// the first whose arity matches. A factory with trailing defaulted parameters
// (so its declared arity exceeds the supplied count) previously lost to a
// same-name single-parameter factory of an unrelated type.
interface Shape {
    fun describe(): String
}

class Circle(val r: Int) : Shape {
    override fun describe(): String = "circle($r)"
}

class Label(val text: String) : Shape {
    override fun describe(): String = "label($text)"
}

fun Shape(radius: Int, scale: Int = 1): Shape = Circle(radius * scale)
fun Shape(text: String): Shape = Label(text)

fun main() {
    println(Shape(5).describe())
    println(Shape(5, 2).describe())
    println(Shape("hi").describe())
}
