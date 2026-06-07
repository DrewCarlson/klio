fun interface Greeter {
    fun greet(name: String): String
}

fun apply(g: Greeter, n: String): String = g.greet(n)

fun main() {
    println(apply({ s -> "hi $s" }, "ada"))
}
