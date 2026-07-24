fun <T> select(value: T): String = "generic"
fun select(value: String): String = "string"

fun relay(value: Any) {
    println(select(value))
}

fun named(vararg x: Int): String = "vararg"
fun named(x: Int): String = "fixed"

fun main() {
    relay(1)
    relay("text")
    println(named(x = 1))
}
