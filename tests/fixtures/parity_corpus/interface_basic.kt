interface Greeter {
    fun greet(): String
}

class Hello : Greeter {
    override fun greet(): String = "hello"
}

fun main() {
    val g: Greeter = Hello()
    println(g.greet())
}
