interface Greeter {
    fun greet(name: String): String
}

class FormalGreeter : Greeter {
    override fun greet(name: String) = "Good day, $name."
}

class Wrapped(g: Greeter) : Greeter by g {
    override fun greet(name: String) = "Yo, $name!"
}

fun main() {
    val w = Wrapped(FormalGreeter())
    println(w.greet("World"))
}
