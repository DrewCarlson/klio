class Counter {
    companion object Factory {
        val tag: String = "counter"
        fun build(start: Int): Counter {
            val c = Counter()
            c.value = start
            return c
        }
    }
    var value: Int = 0
}

fun main() {
    println(Counter.tag)
    val c = Counter.build(10)
    println(c.value)
    println(Counter.Factory.tag)
    println(Counter.Factory.build(5).value)
}
