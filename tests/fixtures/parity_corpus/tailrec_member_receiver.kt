// A tailrec instance method's bare recursive call keeps its receiver:
// the tail jump must re-bind ALL params including the implicit `this`,
// or every re-bound parameter shifts by one and the walk returns the
// wrong value (kotlinc-verified output below).
open class Chain(val tag: String) {
    var prev: Chain? = null
    open val gone: Boolean get() = false

    fun firstLive(): Chain = findLive(this)

    private tailrec fun findLive(current: Chain): Chain {
        if (!current.gone) return current
        return findLive(current.prev!!)
    }

    tailrec fun countBack(current: Chain, acc: Int): Int {
        val p = current.prev ?: return acc + 1
        return countBack(p, acc + 1)
    }
}

class DeadLink(tag: String) : Chain(tag) {
    override val gone: Boolean get() = true
}

fun main() {
    val a = Chain("a")
    val b = DeadLink("b")
    val c = DeadLink("c")
    b.prev = a
    c.prev = b
    println(c.firstLive().tag)
    println(c.countBack(c, 0))
}
