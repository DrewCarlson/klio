// A plain (non-val/var) primary-constructor parameter is in scope in the
// class's property initializers and init blocks, not in its member bodies.
// A member that needs the value reads a property initialized from it. Covers
// a leaf param, a param also passed to a super constructor, and a param whose
// name matches an inherited property: in a member body that name is the
// inherited property.
package p

open class Base(val root: Int) {
    open fun describe(): String = "base:$root"
}

// `seed` is plain: an initializer keeps it in a property the members read.
class Holder(seed: Int) {
    private val kept = seed
    fun get(): Int = kept
    fun doubled(): Int = kept * 2
}

// `tag` is plain and kept the same way; `root` is plain and passed to super,
// so `root` in a member body is the inherited `Base.root`.
class Derived(tag: String, root: Int) : Base(root) {
    private val label = tag
    override fun describe(): String = "$label/$root"
    fun onlyTag(): String = label
}

fun main() {
    val h = Holder(21)
    println(h.get())
    println(h.doubled())

    val d = Derived("x", 5)
    println(d.describe())
    println(d.onlyTag())
    println(d.root)
}
