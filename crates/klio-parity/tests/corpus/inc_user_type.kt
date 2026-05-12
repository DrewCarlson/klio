class Counter(val n: Int) {
    operator fun inc(): Counter = Counter(n + 1)
    operator fun dec(): Counter = Counter(n - 1)
    override fun toString(): String = "C($n)"
}

fun main() {
    var c = Counter(0)
    println(c++)
    println(c)
    println(++c)
    println(c)
    println(c--)
    println(c)
    println(--c)
}
