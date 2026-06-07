// expect-error: T0065
open class B { open fun f(): Int = 1 }
class D : B() { override fun f(): Any = "x" }
fun main() { D() }
