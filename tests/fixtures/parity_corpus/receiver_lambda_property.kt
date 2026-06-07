// A function-typed property invoked extension-style (`x.convertTo()` where
// `convertTo: From.() -> To` is a property) must invoke the lambda, even when
// a same-named member extension on a different receiver type also exists —
// and even from inside a nested anonymous object whose outer holds the
// property (ktor's DelegatingMutableSet shape).
class Wrap<From, To>(
    private val items: List<From>,
    private val convertTo: From.() -> To,
) {
    // Same-named member extension on a *collection* receiver.
    fun Collection<From>.convertTo(): List<To> = map { it.convertTo() }

    fun first(): To = items.first().convertTo()                 // direct method
    fun all(): List<To> = items.convertTo().toList()            // member extension
    fun iter(): Iterator<To> = object : Iterator<To> {          // anon object
        val d = items.iterator()
        override fun hasNext(): Boolean = d.hasNext()
        override fun next(): To = d.next().convertTo()           // outer's property
    }
}

fun main() {
    val w = Wrap(listOf(1, 2, 3)) { "n$this" }
    println(w.first())
    println(w.all())
    val it = w.iter()
    val out = StringBuilder()
    while (it.hasNext()) out.append(it.next()).append(' ')
    println(out.toString().trim())
}
