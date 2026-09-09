// Every backing field exists from allocation holding its type's zero, exactly as
// on the JVM: a superclass `init` that calls an overridden method sees the
// subclass's field as 0/false/null, not as missing. The initializer overwrites it
// afterwards. Reading `n` during `A.init` printed a `get_field` error before the
// slots were pre-declared.
open class A {
    init { show() }
    open fun show() {}
}

class B : A() {
    var n = 5
    var flag = true
    var label: String? = null
    override fun show() { println("during A.init: n=" + n + " flag=" + flag + " label=" + label) }
}

class WithAnnotated : A() {
    var count: Long = 7L
    override fun show() { println("during A.init: count=" + count) }
}

fun main() {
    val b = B()
    b.show()
    WithAnnotated().show()
}
