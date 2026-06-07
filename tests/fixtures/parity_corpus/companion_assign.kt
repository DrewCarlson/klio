class Counter {
    companion object {
        var count = 0
        fun reset() { count = 0 }
    }
}

fun main() {
    Counter.count = 5
    println(Counter.count)
    Counter.count += 3
    println(Counter.count)
    Counter.reset()
    println(Counter.count)
}
