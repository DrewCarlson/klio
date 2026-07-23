fun Any.tag(): String = "outer"

fun main() {
    fun List<String>.tag(): String = "local"

    val values: List<Int> = listOf(1)
    println(values.tag())
}
