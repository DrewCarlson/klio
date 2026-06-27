fun greet(x: Int): String = "global:$x"

open class Base {
    fun greet(): String = "member"
}

class Derived : Base() {
    fun probe(): String = greet(5)
}

fun main() {
    println(Derived().probe())
}
