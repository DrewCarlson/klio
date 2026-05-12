// expect-error: T0069
open class B { open suspend fun f() {} }
class D : B() { override fun f() {} }
fun main() { D() }
