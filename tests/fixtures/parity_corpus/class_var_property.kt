class Counter(var n: Int) {
    fun bump() { n = n + 1 }
}

fun main() {
    val c = Counter(10)
    println(c.n)
    c.bump()
    c.bump()
    println(c.n)
    c.n = 100
    println(c.n)
}
