// Inside a receiver lambda passed to an inline function `f`, `this@f` names the
// lambda's OWN receiver and shadows `f`'s extension receiver of the same label.
// The two `encodeColl` overloads below mirror kotlinx.serialization's
// `encodeCollection`: the caller's element block, invoked from a nested lambda
// inside the spliced receiver literal, must run against the collection
// encoder (`child`) that `begin()` opened — never the enclosing `outer`.
interface CE { fun elem(i: Int, s: String) }
interface Enc { fun begin(): CE }

class Child : CE { override fun elem(i: Int, s: String) = println("child[$i]=$s") }
class Outer : Enc, CE {
    override fun begin(): CE = Child()
    override fun elem(i: Int, s: String) = println("outer[$i]=$s")
}

inline fun Enc.encodeColl(crossinline block: CE.() -> Unit) {
    val composite = begin()
    composite.block()
}

inline fun <E> Enc.encodeColl(items: List<E>, crossinline block: CE.(Int, E) -> Unit) {
    encodeColl { items.forEachIndexed { index, e -> block(index, e) } }
}

object Ser {
    fun serialize(encoder: Enc, value: List<String>) {
        encoder.encodeColl(value) { index, item -> elem(index, item) }
    }
}

fun main() {
    Ser.serialize(Outer(), listOf("a", "b"))
    // The same shape with the outer receiver's own type distinct from CE.
    val direct = Outer()
    direct.encodeColl(listOf("x")) { index, item -> elem(index, item) }
}
