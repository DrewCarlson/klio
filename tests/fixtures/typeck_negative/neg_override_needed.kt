open class Base {
    open fun hello(): String = "base"
}

class Sub : Base() {
    fun hello(): String = "sub"
}

fun main() {
    println(Sub().hello())
}
