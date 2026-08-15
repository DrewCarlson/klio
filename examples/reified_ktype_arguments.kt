// typeOf<T>() materialises generic ARGUMENTS, both directly and through a
// reified chain (typeInfo-style wrappers), and structural contains on lists
// of pairs dispatches a user equals through the tuple components.

import kotlin.reflect.KClass
import kotlin.reflect.typeOf

class Money(val cents: Int) {
    override fun equals(other: Any?): Boolean = other is Money && other.cents == cents
    override fun hashCode(): Int = cents
}

inline fun <reified T> describe(): String {
    val t = typeOf<T>()
    val head = (t.classifier as? KClass<*>)?.simpleName ?: "?"
    val args = t.arguments.size
    return "$head/$args"
}

fun main() {
    println(describe<List<Int>>())
    println(describe<Map<String, List<Int>>>())
    println(describe<String>())
    val t = typeOf<List<Int>>()
    val inner = t.arguments.single().type
    println((inner?.classifier as? KClass<*>)?.simpleName)

    val priced = listOf("a" to Money(100), "b" to Money(250))
    println(priced.contains("b" to Money(250)))
    println(priced.contains("b" to Money(999)))
    println(priced.indexOf("a" to Money(100)))
    println("done")
}
