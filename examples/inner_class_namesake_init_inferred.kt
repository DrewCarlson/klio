// Two outer classes each declare an inner `Context` and a `Holder(val ref:
// Context)`, unqualified: the nested name resolves to the enclosing class's
// own inner class, so `holder.ref.items` inside `Link` is Link.Context's
// `items` (a `MutableSet`, initializer-inferred) and `forEach` iterates it —
// never Gap.Context's same-named `items`, which is a `MutableList` with a
// different element type and its own iteration.

class Gap {
    inner class Context {
        val items = mutableListOf<Int>()
    }
    inner class Holder(val ref: Context)

    fun total(holder: Holder): Int {
        var sum = 0
        holder.ref.items.forEach { sum += it }
        return sum
    }
}

class Link {
    inner class Context {
        val items = mutableSetOf<String>()
    }
    inner class Holder(val ref: Context)

    fun report(any: Any?): String {
        fun reportGroup(depth: Int): String {
            val holder = any as? Holder
            if (holder != null) {
                val context = holder.ref
                val sb = StringBuilder()
                context.items.forEach { name -> sb.append(name).append('@').append(depth).append(' ') }
                return sb.toString().trim()
            }
            return "none"
        }
        return reportGroup(2)
    }
}

fun main() {
    val gap = Gap()
    val gc = gap.Context()
    gc.items.add(4); gc.items.add(5)
    println(gap.total(gap.Holder(gc)))
    val link = Link()
    val lc = link.Context()
    lc.items.add("a"); lc.items.add("b")
    println(link.report(link.Holder(lc)))
    println(link.report(null))
    println(lc.items.size.toString() + " " + gc.items.size)
}
