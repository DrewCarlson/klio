class Greeter(val name: String) {
    val message: String
    init {
        println("ctor start: $name")
        message = "hello, $name"
    }
    init {
        println("ctor end: $message")
    }
}

fun main() {
    val g = Greeter("world")
    println(g.message)
}
