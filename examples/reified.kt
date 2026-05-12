// M28 reified type parameters on inline functions.
inline fun <reified T> isAnInstance(value: Any): Boolean = value is T

fun main() {
    println(isAnInstance<String>("hi"))
    println(isAnInstance<String>(7))
    println(isAnInstance<Int>(7))
}
