// A labeled return from a scoped-function block exits the lambda only;
// the scoped function still completes normally. The receiver being a
// constructor call must not change which call the label binds to.
class Stack {
    val xs = ArrayList<Int>()
    fun push(x: Int) { xs.add(x) }
}

inline fun walk(n: Int, block: (Int) -> Unit) {
    for (i in 0 until n) block(i)
}

fun main() {
    val direct = Stack().apply {
        if (xs.isEmpty()) return@apply
        push(9)
    }
    println(direct.xs)

    val nested = Stack().apply {
        walk(5) { p ->
            if (p == 3) return@apply
            push(p)
        }
    }
    println(nested.xs)

    val labeled = Stack().apply lbl@{
        walk(3) { p ->
            if (p == 1) return@lbl
            push(p)
        }
    }
    println(labeled.xs)

    val viaAlso = Stack().also {
        if (it.xs.size == 0) return@also
        it.push(7)
    }
    println(viaAlso.xs)
}
