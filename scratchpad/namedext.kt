interface Src { fun tag(): String }
class S(val n: Int) : Src { override fun tag() = "S$n" }

class Coll { val seen = StringBuilder() }

// extension with 3 params, mirroring FlowCollector<R>.combineInternal
fun <T> Coll.take(items: Array<out T>, factory: () -> Int, xform: (T) -> String) {
    seen.append("n=" + items.size + " f=" + factory() + " ")
    for (i in 0 until items.size) seen.append(xform(items[i]))
}

// expression-body caller: all positional (the vararg overload's shape)
fun positional(a: Src, b: Src): String {
    val c = Coll()
    c.take(arrayOf(a, b), { 7 }, { it.tag() })
    return c.seen.toString()
}

// block-body caller with NAMED args (the Iterable overload's shape)
fun named(a: Src, b: Src): String {
    val c = Coll()
    val arr = listOf(a, b).toTypedArray()
    c.take(arr, factory = { arr.size }, xform = { it.tag() })
    return c.seen.toString()
}

fun main() {
    println("positional: " + positional(S(1), S(2)))
    println("named     : " + named(S(1), S(2)))
}
