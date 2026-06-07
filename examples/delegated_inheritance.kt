// Demonstrates that a delegated property declared on a parent class is
// accessible through subclass instances and resolves through the parent's
// delegate.
open class Base {
    val greeting: String by lazy { "hi-from-base" }
}

class Sub : Base()

fun main() {
    val s = Sub()
    println(s.greeting)
    println(s.greeting)
    val viaParent: Base = s
    println(viaParent.greeting)
}
