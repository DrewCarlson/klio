object Counter {
    var n = 0
    fun bump() { n = n + 1 }
    fun greet(name: String): String = "hello, $name (n=$n)"
}

fun main() {
    println(Counter.n)
    Counter.bump()
    Counter.bump()
    Counter.bump()
    println(Counter.n)
    println(Counter.greet("world"))
}
