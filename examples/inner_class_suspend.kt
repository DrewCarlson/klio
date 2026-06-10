// Inner-class construction captures the right enclosing instance from
// every context: a member body, a `with` receiver lambda (whose subject
// must NOT be captured — even when it declares a same-named property), an
// HOF lambda, a user-defined HOF, a member of the inner class constructing
// a sibling `Inner()` (the outer comes through the dispatch receiver's own
// outer link, never an unrelated receiver such as a caller's `with`
// subject), a later-declared sibling inner class built from a lambda, and
// a suspend member that parks at `delay` before constructing the Inner.
import kotlinx.coroutines.*

class Helper(val hid: String)

class Shadow(val tag: String)

fun runBlock(f: () -> String): String = f()

class Outer(val tag: String) {
    inner class Inner {
        fun show(): String = "outer=$tag"

        fun sibling(): Inner = Inner()

        fun twin(): Later = listOf(1).map { Later() }.first()
    }

    inner class Later {
        fun show(): String = "later=$tag"
    }

    fun direct(): String = Inner().show()

    fun mk(): Inner = Inner()

    fun viaWith(h: Helper): String = with(h) { Inner().show() + "+" + hid }

    fun viaShadowedWith(s: Shadow): String = with(s) { Inner().show() }

    fun viaUserHof(): String = runBlock { Inner().show() }

    fun viaMap(): String = listOf(1, 2).map { Inner().show() }.joinToString(",")

    suspend fun build(): String {
        delay(5)
        return Inner().show()
    }

    suspend fun buildVia(h: Helper): String {
        delay(5)
        return with(h) { Inner().show() + "+" + hid }
    }
}

fun main() = runBlocking {
    val o = Outer("sync")
    println(o.direct())
    println(o.viaWith(Helper("w")))
    println(o.viaShadowedWith(Shadow("never")))
    println(o.viaUserHof())
    println(o.viaMap())
    val inner = Outer("sib").mk()
    println(inner.sibling().show())
    println(with(Outer("unrelated")) { inner.sibling() }.show())
    println(inner.twin().show())
    val a = async { Outer("A").build() }
    val b = async { Outer("B").buildVia(Helper("x")) }
    println(a.await())
    println(b.await())
}
