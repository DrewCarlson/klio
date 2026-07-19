// A plain (non-val/var) primary-constructor parameter that a member body
// reads is captured by Kotlin as a synthesized field, so it stays available
// after construction. Covers a leaf param, a param also passed to a super
// constructor, and a param whose name matches an inherited property (which
// keeps the inherited field, not a duplicate).
package p

open class Base(val root: Int) {
    open fun describe(): String = "base:$root"
}

// `seed` is plain, used only in method bodies -> synthesized field.
class Holder(seed: Int) {
    fun get(): Int = seed
    fun doubled(): Int = seed * 2
}

// `tag` is plain and passed to super; `root` is plain and shadows Base.root
// (the inherited `root` field is used, no duplicate cell).
class Derived(tag: String, root: Int) : Base(root) {
    override fun describe(): String = "$tag/$root"
    fun onlyTag(): String = tag
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
