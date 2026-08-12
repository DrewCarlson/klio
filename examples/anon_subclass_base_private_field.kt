// A member extension declared on an abstract base reads the base's private
// field through the dispatch receiver. When the receiver is an anonymous
// object (one or two subclass hops down), the ownership check must recognize
// the anonymous class's supertype chain — the module registry has no name row
// for `$anon$N`, so the runtime class closure is the authority.

interface Scope {
    fun compose(i: Int): Int
}

abstract class Provider {
    private val cache = mutableMapOf<Int, Int>()

    fun Scope.getP(i: Int): Int {
        val c = cache[i]
        return if (c != null) {
            c + 100
        } else {
            compose(i).also { cache[i] = it }
        }
    }
}

abstract class ListProvider(private val measureScope: Scope) : Provider() {
    fun getAndMeasure(index: Int): Int = measureScope.getP(index)
}

fun main() {
    val sc = object : Scope {
        override fun compose(i: Int): Int = i * 2
    }
    val direct = object : Provider() {}
    with(direct) {
        println(sc.getP(3))
        println(sc.getP(3))
    }
    val lp = object : ListProvider(sc) {}
    println(lp.getAndMeasure(5))
    println(lp.getAndMeasure(5))
}
