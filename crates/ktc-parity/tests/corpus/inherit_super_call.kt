open class Greeter(val name: String) {
    open fun greet(): String = "hello, $name"
}

class LoudGreeter(name: String) : Greeter(name) {
    override fun greet(): String = "${super.greet().uppercase()}!"
}

fun main() {
    val g = LoudGreeter("ada")
    println(g.greet())
}
