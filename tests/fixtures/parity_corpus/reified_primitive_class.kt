inline fun <reified T> typeName(): String = T::class.simpleName ?: "?"

fun main() {
    println(typeName<Int>())
    println(typeName<String>())
    println(Int::class.simpleName)
    println(Long::class.qualifiedName)
}
