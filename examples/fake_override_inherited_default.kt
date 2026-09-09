// A class inherits a method's BODY from its superclass (which declares no
// default) and the method's DEFAULT from an interface (a bodyless
// declaration). Calling the method with the argument omitted fills the gap
// from the interface's default, then runs the inherited body.

interface Named {
    val label: String
    fun greet(who: String = "world"): String
    fun tag(x: String = label): String
}

open class Base {
    open fun greet(who: String) = "hi $who"
    open fun tag(x: String) = "[$x]"
}

class Impl : Base(), Named {
    override val label get() = "impl"
}

fun main() {
    val n: Named = Impl()
    println(n.greet())        // interface default "world" + Base body
    println(n.tag())          // interface default = label ("impl") + Base body
    val i = Impl()
    println(i.greet("kotlin")) // explicit argument still works
}
