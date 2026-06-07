interface Greeter {
    fun greet(name: String): String
    val tag: String
}

class FormalGreeter : Greeter {
    override fun greet(name: String) = "Good day, $name."
    override val tag = "FORMAL"
}

class CasualGreeter : Greeter {
    override fun greet(name: String) = "Hey $name!"
    override val tag = "CASUAL"
}

class Wrapped(g: Greeter) : Greeter by g

class Loud(g: Greeter) : Greeter by g {
    override fun greet(name: String) = "HEY ${name.uppercase()}"
}

fun main() {
    val plain = Wrapped(FormalGreeter())
    println(plain.greet("World"))
    println(plain.tag)
    val loud = Loud(CasualGreeter())
    println(loud.greet("World"))
    println(loud.tag)
}
