// expect-error: T0066
open class B { open var x: Int = 1 }
class D : B() { override val x: Int = 2 }
fun main() { D() }
