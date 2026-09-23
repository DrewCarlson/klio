// The indexing and compound-assignment operators are fixed by the convention,
// so they bind to their declaration at lowering. The behaviour they must keep:
// a virtual `get` still dispatches on the runtime class, an extension still
// serves a class with no member, and a builtin container is untouched.
class Grid(val w: Int) {
    private val cells = IntArray(w * w)

    operator fun get(x: Int, y: Int): Int = cells[y * w + x]

    operator fun set(x: Int, y: Int, v: Int) {
        cells[y * w + x] = v
    }
}

open class Box(val n: Int) {
    open operator fun get(i: Int): String = "base$i:$n"
}

class SubBox(n: Int) : Box(n) {
    override operator fun get(i: Int): String = "sub$i:$n"
}

class Bare(val tag: String)

operator fun Bare.get(i: Int): String = "ext$i:$tag"

class Bag {
    val items = mutableListOf<String>()

    operator fun plusAssign(s: String) {
        items += s
    }
}

fun main() {
    val g = Grid(3)
    g[1, 2] = 42
    g[1, 2] = g[1, 2] + 1
    println(g[1, 2])

    val b: Box = SubBox(5)
    println(b[1])
    println(Box(6)[1])

    println(Bare("t")[9])

    val bag = Bag()
    bag += "one"
    bag += "two"
    println(bag.items.joinToString(","))

    val m = mutableMapOf("k" to 1)
    m["k"] = m["k"]!! + 1
    println(m["k"])

    val lst = mutableListOf(1, 2, 3)
    lst[0] = 9
    println(lst.joinToString(","))
    println(StringBuilder("abc")[1])
}
