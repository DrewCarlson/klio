// expect-error: T0067
open class B { open var x: Any = "hi" }
class D : B() { override var x: Int = 1 }
fun main() { D() }
