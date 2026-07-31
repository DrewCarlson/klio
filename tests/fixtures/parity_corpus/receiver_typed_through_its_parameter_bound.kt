// A receiver typed by a TYPE PARAMETER names no class, so a call on it could
// not lend its return type: `M : MutableMap<K, Base>` made `dest.getOrPut`
// yield nothing, and the local it initializes stayed untyped. The parameter's
// declared upper bound carries both the owner class and the type arguments
// instantiation needs; a use-site projection in the bound (`in K`) behaves as
// the plain parameter for deriving a return type. `groupByTo` and every
// grouping helper in the stdlib write exactly this shape.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun <K, M : MutableMap<K, Base>> fill(dest: M, key: K): String {
    val v = dest.getOrPut(key) { Derived() }
    return v.tag()
}

fun <T, K, M : MutableMap<in K, MutableList<T>>> groupInto(dest: M, key: K, item: T): Int {
    val list = dest.getOrPut(key) { mutableListOf() }
    list.add(item)
    return list.size
}

fun main() {
    println(fill(mutableMapOf<String, Base>(), "k"))
    val groups = mutableMapOf<String, MutableList<Int>>()
    println(groupInto(groups, "a", 1))
    println(groupInto(groups, "a", 2))
}
