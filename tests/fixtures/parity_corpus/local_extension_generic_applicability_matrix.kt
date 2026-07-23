typealias Ints = MutableList<Int>

class Box<out T>

fun Any.tag(): String = "outer"

fun bottomCase() {
    fun List<String>.tag(): String = "local"

    val values: List<Nothing> = emptyList()
    println(values.tag())
}

fun starCase() {
    fun MutableList<String>.tag(): String = "local"

    val values: MutableList<*> = mutableListOf(1)
    println(values.tag())
}

fun varianceCase() {
    fun Box<String>.tag(): String = "local"

    val value: Box<Any> = Box()
    println(value.tag())
}

fun aliasCase() {
    fun MutableList<String>.tag(): String = "local"

    val values: Ints = mutableListOf(1)
    println(values.tag())
}

fun <T> typeVariableCase(values: List<T>) {
    fun List<String>.tag(): String = "local"

    println(values.tag())
}

fun projectionCase() {
    fun MutableList<String>.tag(): String = "local"

    val values: MutableList<out Any> = mutableListOf(1)
    println(values.tag())
}

fun main() {
    bottomCase()
    starCase()
    varianceCase()
    aliasCase()
    typeVariableCase(listOf(1))
    projectionCase()
}
