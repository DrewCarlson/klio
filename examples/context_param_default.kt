// A default argument that references a context parameter resolves it the
// way the function body does: the default is evaluated at call time with
// the context on the stack, so `b = a` reads the context receiver.
class C(val value: String)

context(a: C)
fun useContext(b: C = a): String = b.value

fun main() {
    with(C("OK")) {
        println(useContext())
        println(useContext(C("EXPLICIT")))
    }
}
