// An overload set discriminated by a function-type argument resolves to the
// same target on every call, so the resolution is cacheable even though the
// candidate set had more than one member.
interface I {
    fun f(msg: () -> String?, actual: Boolean): Int = if (actual) 1 else (msg()?.length ?: 0)
    fun f(msg: String?, actual: Boolean): Int = if (actual) 2 else (msg?.length ?: 0)
}
object O : I
val iface: I get() = O

open class Base
class Derived : Base()
class Picky {
    fun g(x: Base): String = "base"
    fun g(x: Derived): String = "derived"
    fun h(x: Int): String = "int"
    fun h(x: String): String = "string"
}

fun main() {
    var lazySum = 0
    var plainSum = 0
    for (i in 1..4) {
        lazySum += iface.f({ "abcd" }, i % 2 == 0)
        plainSum += iface.f("abcd", i % 2 == 0)
    }
    println("$lazySum $plainSum")

    val p = Picky()
    val b: Base = Base()
    val d = Derived()
    println(p.g(b) + "/" + p.g(d) + "/" + p.g(b) + "/" + p.g(d))
    println(p.h(1) + "/" + p.h("x") + "/" + p.h(2) + "/" + p.h("y"))
}
