private val LOGGER by lazy { "logger-b" }

fun useB(): String = LOGGER

fun main() {
    println(useA())
    println(useB())
}
