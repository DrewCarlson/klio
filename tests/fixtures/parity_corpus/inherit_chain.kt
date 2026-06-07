open class A {
    open fun who(): String = "A"
}

open class B : A() {
    override fun who(): String = "B(${super.who()})"
}

class C : B() {
    override fun who(): String = "C(${super.who()})"
}

fun main() {
    val a = A()
    val b = B()
    val c = C()
    println(a.who())
    println(b.who())
    println(c.who())
}
