open class Base {
    fun hello(): String = "base"
}

class Sub : Base() {
    override fun goodbye(): String = "sub"
}

fun main() {
    println(Sub().goodbye())
}
