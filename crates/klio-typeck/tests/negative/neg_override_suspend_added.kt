// expect-error: T0069
open class B { open fun f() {} }
class D : B() { override suspend fun f() {} }
fun main() { D() }
