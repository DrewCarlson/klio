interface B {
    fun frac(minLength: Int = 1, maxLength: Int = 9): String
    fun frac(fixedLength: Int): String = frac(fixedLength, fixedLength)
}
class Impl : B {
    override fun frac(minLength: Int, maxLength: Int): String = "min=$minLength max=$maxLength"
}

open class C {
    open fun g(a: Int = 1, b: Int = 9): String = "ab($a,$b)"
    fun g(only: Int): String = "only($only)"
}

fun main() {
    val i: B = Impl()
    println("iface pos   = " + i.frac(3))
    println("iface named = " + i.frac(fixedLength = 3))
    val c = C()
    println("class pos   = " + c.g(3))
    println("class named = " + c.g(only = 3))
}
