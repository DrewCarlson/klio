// `inc` is a zero-arg operator; declaring it with a parameter is a
// signature mismatch. Expect a T0088 warning diagnostic.

class Counter(val n: Int) {
    operator fun inc(by: Int): Counter = Counter(n + by)
}

fun main() {
    val c = Counter(0)
    println(c.n)
}
