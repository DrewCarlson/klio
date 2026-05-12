class Holder {
    lateinit var name: String

    fun greet(): String = "hello $name"
}

fun main() {
    val h = Holder()
    h.name = "world"
    println(h.greet())
    h.name = "kotlin"
    println(h.name)
}
