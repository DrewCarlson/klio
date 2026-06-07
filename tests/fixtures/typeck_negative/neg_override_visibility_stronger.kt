// expect-error: T0068
open class P { open fun g() {} }
class Q : P() { protected override fun g() {} }
fun main() { Q() }
