interface Greeter {
    fun greet(who: String): String
}

object EnglishGreeter : Greeter {
    override fun greet(who: String): String = "hello, $who"
}

val greeter: Greeter = EnglishGreeter

val counterSeed: Int = 40

fun main() {
    println(greeter.greet("klio"))
    println(counterSeed.plus(2))
    val viaLocal = greeter
    println(viaLocal.greet("again"))
}
