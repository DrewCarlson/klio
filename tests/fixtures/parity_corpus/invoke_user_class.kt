class Greeter(val prefix: String) {
    operator fun invoke(name: String): String = "$prefix, $name"
}

class Counter(var n: Int)

operator fun Counter.invoke(): Int { n = n + 1; return n }

fun main() {
    val g = Greeter("hello")
    println(g("world"))
    println(g("kotlin"))

    val c = Counter(0)
    println(c())
    println(c())
    println(c())
}
