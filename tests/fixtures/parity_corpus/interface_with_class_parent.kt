interface Marker

interface Greeter {
    fun greet(): String = "hi"
}

open class Parent(val tag: String) {
    open fun describe(): String = "parent:$tag"
}

class Sub(tag: String) : Parent(tag), Marker, Greeter {
    override fun describe(): String = "sub:$tag"
}

fun main() {
    val s = Sub("x")
    println(s.describe())
    println(s.greet())
    println(s is Marker)
    println(s is Greeter)
    println(s is Parent)
}
