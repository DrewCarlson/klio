package app

fun Any.tag(): String = "outer"

fun main() {
    fun MutableList<String>.tag(): String = "local"

    val values: alpha.Items<Int> = mutableListOf(1)
    println(values.tag())
}
