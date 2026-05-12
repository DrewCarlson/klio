open class Base {
    fun hello(): String = "base"
}

class Sub : Base() {
    override fun hello(): String = "sub"
}

fun main() {
    println(Sub().hello())
}
