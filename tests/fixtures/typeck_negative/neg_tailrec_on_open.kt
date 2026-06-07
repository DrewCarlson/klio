open class Counter {
    open tailrec fun loop(n: Int) {
        if (n == 0) return
        loop(n - 1)
    }
}

fun main() {
    Counter().loop(3)
}
