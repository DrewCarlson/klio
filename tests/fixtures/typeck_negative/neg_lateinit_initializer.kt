// `lateinit` cannot be combined with an initializer. Expect T0016.

class Box {
    lateinit var name: String = "hi"
}

fun main() {
    println(Box())
}
