// Labeled super from an inner class: `super@Outer.f()` and `super<K>@Outer.f()`
// start at the OUTER class's supertypes and run against the outer instance
// (`this@Outer`), so an override on the outer class is what the base body
// calls back into. Unlabeled `super` and `super<K>` stay on the inner class.
// The same holds for property reads, plain writes and compound writes.
//
// Run with: klio run examples/labeled_super_calls.kt

interface BK {
    fun foo(): String
    fun bar(): String
}

interface K : BK {
    override fun foo() = bar()
}

class A : K {
    override fun foo() = "A.foo"
    override fun bar() = "A.bar"

    inner class B : K {
        override fun foo() = "B.foo"
        override fun bar() = "B.bar"

        fun labeledQualified() = super<K>@A.foo()
        fun selfLabeledQualified() = super<K>@B.foo()
        fun qualified() = super<K>.foo()
        fun labeled() = super@A.foo()
        fun selfLabeled() = super@B.foo()
        fun plain() = super.foo()
    }
}

open class M {
    open fun x(): Int = 10
    open var y = 500
}

open class N : M() {
    override fun x(): Int = 20
    override var y = 200

    inner class C {
        fun outerBase() = super<M>@N.x()
        fun outerBaseProperty() = super<M>@N.y
        fun bumpOuterBase(): Int {
            super<M>@N.y += 200
            return super<M>@N.y
        }
    }
}

fun main() {
    val b = A().B()
    println(b.labeledQualified())
    println(b.selfLabeledQualified())
    println(b.qualified())
    println(b.labeled())
    println(b.selfLabeled())
    println(b.plain())

    val n = N()
    val c = n.C()
    println(c.outerBase())
    println(c.outerBaseProperty())
    println(c.bumpOuterBase())
    println(n.y)
}
