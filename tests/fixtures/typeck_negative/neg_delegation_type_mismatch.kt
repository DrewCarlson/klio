interface Greeter {
    fun greet(): String
}

class Counter(val n: Int)

class Wrap(c: Counter) : Greeter by c

fun main() {
    val w = Wrap(Counter(1))
    println(w.greet())
}
