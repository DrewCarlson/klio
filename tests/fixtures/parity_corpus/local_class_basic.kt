fun main() {
    class Counter(var n: Int) {
        fun bump() { n = n + 1 }
    }
    val c = Counter(0)
    c.bump()
    c.bump()
    c.bump()
    println(c.n)
}
