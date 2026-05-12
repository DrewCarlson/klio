// expect-error: T0070
open class B {
    private open fun f() {}
}
fun main() { B() }
