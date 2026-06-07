// `lateinit` is not allowed on primitive types. Expect T0015.

class Counter {
    lateinit var n: Int
}

fun main() {
    println(Counter())
}
