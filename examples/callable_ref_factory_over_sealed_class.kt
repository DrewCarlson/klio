// A callable reference to a name shared by a SEALED class and its factory
// functions (`::P`, like kotlinx's `::JsonPrimitive`) binds the factory
// overloads: the class cannot construct the argument, so dispatch picks the
// overload by the argument's runtime type, widening `Int` to `Number?`.
sealed class P { abstract val s: String }
class PN(val n: Number) : P() { override val s get() = "n$n" }
class PS(val str: String) : P() { override val s get() = "s$str" }
fun P(value: Number?): P = PN(value ?: 0)
fun P(value: String?): P = PS(value ?: "")

fun main() {
    println(listOf(1, 2).map(::P).map { it.s })
    println(listOf("a", "b").map(::P).map { it.s })
    val f: (Int) -> P = ::P
    println(f(7).s)
    val g: (String?) -> P = ::P
    println(g(null).s)
}
