fun Any.tag(): String = "outer"

fun <T> scope(value: T, block: T.() -> String): String = value.block()

fun main() {
    fun List<String>.tag(): String = "local"

    val values: List<Int> = listOf(1)
    println(scope<List<Int>>(values) { tag() })
}
