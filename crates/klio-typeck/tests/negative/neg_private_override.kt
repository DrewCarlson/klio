// expect-error: T0070
open class B { open fun f() {} }
class D : B() {
    private override fun f() {}
}
fun main() { D() }
