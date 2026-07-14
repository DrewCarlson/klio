// A field-backed `override var` overrides an inherited accessor-based property:
// a write stores the field and does NOT reach the base class's custom setter,
// even through an intermediate class.

open class Base {
    open var count: Int
        get() = 0
        set(value) { error("base setter must not run") }
}

open class Mid : Base() {
    override var count: Int = 0
}

class Leaf : Mid()

fun main() {
    val leaf = Leaf()
    leaf.count = 5
    println("leaf.count = " + leaf.count)

    val mid: Base = Mid()
    mid.count = 7
    println("mid.count = " + mid.count)
}
