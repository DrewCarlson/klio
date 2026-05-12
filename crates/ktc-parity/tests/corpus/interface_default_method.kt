interface Greeter {
    fun name(): String
    fun greet(): String = "hello, ${name()}"
}

class English : Greeter {
    override fun name(): String = "world"
}

class Spanish : Greeter {
    override fun name(): String = "mundo"
}

fun main() {
    println(English().greet())
    println(Spanish().greet())
}
