class Counter(var n: Int = 0)

fun main() {
    val c: Counter? = Counter(10)
    c?.n += 5
    println(c?.n)
    c?.n -= 3
    println(c?.n)
    val z: Counter? = null
    z?.n += 100
    println(z?.n)
}
