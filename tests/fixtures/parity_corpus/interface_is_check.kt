interface Greeter {
    fun greet(): String
}

class Hello : Greeter {
    override fun greet(): String = "hello"
}

class NotAGreeter

fun describe(x: Any): String {
    return if (x is Greeter) "greeter: ${x.greet()}" else "other"
}

fun main() {
    println(describe(Hello()))
    println(describe(NotAGreeter()))
    println(describe(42))
}
