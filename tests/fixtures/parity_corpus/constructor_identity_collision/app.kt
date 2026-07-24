package constructor.identity.app

class Token(val value: Int) {
    override fun toString(): String = "ctor"
}

fun Token(value: Any): String = "factory"

fun main() {
    println(Token(1))
}
