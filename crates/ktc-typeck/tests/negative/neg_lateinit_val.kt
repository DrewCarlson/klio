// `lateinit val` is not allowed — only `lateinit var`. Expect T0014.

class Box {
    lateinit val name: String
}

fun main() {
    println(Box())
}
