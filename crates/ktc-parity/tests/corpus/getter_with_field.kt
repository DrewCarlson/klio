class Counter {
    var n: Int = 0
        get() = field
        set(value) {
            field = value
        }
}

fun main() {
    val c = Counter()
    c.n = 7
    println(c.n)
}
