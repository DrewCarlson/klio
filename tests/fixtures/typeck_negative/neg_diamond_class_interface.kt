// expect-error: T0013
open class B {
    open fun f(): String = "B"
}
interface I {
    fun f(): String = "I"
}
class D : B(), I
fun main() { println(D().f()) }
