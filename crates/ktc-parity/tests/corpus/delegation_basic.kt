interface Greeter {
    fun greet(name: String): String
    val tag: String
}

class FormalGreeter : Greeter {
    override fun greet(name: String) = "Good day, $name."
    override val tag = "FORMAL"
}

class Wrapped(g: Greeter) : Greeter by g

fun main() {
    val w = Wrapped(FormalGreeter())
    println(w.greet("World"))
    println(w.tag)
}
