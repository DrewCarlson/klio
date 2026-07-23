class Box<out T>

fun Any.tag(): String = "outer"

fun main() {
    fun Box<String>.tag(): String = "local"

    val value: Box<out String> = Box()
    println(value.tag())
}
