// A star projection may appear inside the explicit type arguments of
// a generic call/constructor (`ArrayList<List<*>>()`), not just in
// type-annotation position. Upstream kotlinx-coroutines uses this in
// EventLoop / BufferedChannel / BroadcastChannel. Arithmetic `*` at
// expression depth is unaffected.
fun main() {
    val a = ArrayList<List<*>>()
    a.add(listOf(1, 2))
    a.add(listOf("x"))
    println(a.size)

    val b = HashMap<String, MutableList<*>>()
    b["k"] = mutableListOf(1)
    println(b.size)

    val c = 6 * 7
    println(c)

    val nested = ArrayList<HashMap<String, List<*>>>()
    println(nested.size)
}
