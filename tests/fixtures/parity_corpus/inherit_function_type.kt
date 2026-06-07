class Adder(val base: Int) : (Int) -> Int {
    override fun invoke(x: Int): Int = base + x
}

class Greet : () -> String {
    override fun invoke(): String = "hello"
}

fun main() {
    val a = Adder(10)
    println(a(5))
    val f: (Int) -> Int = Adder(100)
    println(f(7))
    val g = Greet()
    println(g())
}
