interface Greeter {
    fun greet(): String
}

fun main() {
    val g: Greeter = object : Greeter {
        override fun greet(): String = "hi"
    }
    println(g.greet())
}
