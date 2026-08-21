// `dest += e` on an IMMUTABLE binding is `dest.plusAssign(e)` — never a
// rebind — including when the binding is a function parameter captured by a
// nested lambda. Boxing the parameter as if the lambda reassigned it
// detached the caller's collection: `Flow.associateTo(destination)` filled a
// private copy and handed back an empty map.
//
// Run with: klio run examples/compound_assign_captured_parameter.kt

fun fill(dest: MutableMap<String, Int>, keys: List<String>) {
    keys.forEach { dest += (it to it.length) }
}

fun fillList(dest: MutableList<Int>, n: Int) {
    val add = { v: Int -> dest += v }
    repeat(n) { add(it * 10) }
}

inline fun <K, V, M : MutableMap<in K, in V>> fillInline(dest: M, entries: List<Pair<K, V>>): M {
    entries.forEach { dest += it }
    return dest
}

fun main() {
    val m = mutableMapOf<String, Int>()
    fill(m, listOf("a", "bb"))
    println("map    = " + m)

    val l = mutableListOf<Int>()
    fillList(l, 3)
    println("list   = " + l)

    println("inline = " + fillInline(mutableMapOf<String, Int>(), listOf("x" to 1)))

    // A captured VAR still boxes: the lambda's rebind must reach the caller.
    var count = 0
    listOf(1, 2, 3).forEach { count += it }
    println("var    = " + count)
}
