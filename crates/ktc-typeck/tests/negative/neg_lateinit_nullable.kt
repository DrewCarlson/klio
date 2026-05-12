// `lateinit` is not allowed on nullable types. Expect T0017.

class Box {
    lateinit var name: String?
}

fun main() {
    println(Box())
}
