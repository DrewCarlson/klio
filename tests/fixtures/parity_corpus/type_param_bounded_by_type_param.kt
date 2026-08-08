// A type parameter bounded by ANOTHER type parameter of the same function
// (`<S, T : S>`, the shape `runningReduce` uses) constrains nothing a
// concrete argument can be checked against: `S` is itself inferred from the
// call. Treating it as a class rejected the candidate outright, and the call
// was left with no return type.
fun <S, T : S> Iterable<T>.boundReduce(op: (acc: S, e: T) -> S): List<S> {
    val out = ArrayList<S>()
    var acc: S? = null
    for (e in this) {
        acc = if (acc == null) e else op(acc, e)
        out.add(acc)
    }
    return out
}

abstract class Holder<E : Iterable<String>>(val make: (Array<out String>) -> E) {
    fun make(vararg items: String): E = make(items)
    val data = make("foo", "bar")
    fun report(): String {
        val v = data.boundReduce { a, e -> a + e }
        return v.last() + "/" + v.first() + "/" + v.size
    }
}
class Impl : Holder<List<String>>({ it.toList() })

fun main() {
    println(Impl().report())
    println(listOf(1, 2, 3).boundReduce { a, e -> a + e })
}
