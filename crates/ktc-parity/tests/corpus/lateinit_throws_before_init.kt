class Holder {
    lateinit var name: String
}

fun main() {
    val h = Holder()
    try {
        println(h.name)
    } catch (e: RuntimeException) {
        println("caught: ${e.message}")
    }
    h.name = "ok"
    println(h.name)
}
