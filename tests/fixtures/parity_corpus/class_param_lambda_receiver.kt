// A member's receiver-lambda parameter typed by the ENCLOSING CLASS's type
// parameter (`getter: T.() -> P` on `Ctx<out T>`) instantiates from the call
// receiver's own type arguments, so a bare property read in the lambda body
// (`keys`) resolves on the instantiation — and a later uninstantiated
// resolution pass must not clobber the record.
class Ctx<out T>(val expected: T, val actual: T) {
    fun <P> propertyEquals(getter: T.() -> P) { println(expected.getter() == actual.getter()) }
}
fun Ctx<Map<String, Int>>.mapBehavior() {
    propertyEquals { keys.first() }
}
fun main() {
    Ctx(mapOf("a" to 1), mapOf("a" to 1)).mapBehavior()
}
