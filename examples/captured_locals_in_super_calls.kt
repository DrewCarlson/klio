// A local class closes over the enclosing function's locals everywhere in
// its declaration: in its parent-constructor arguments (including lambdas
// and object expressions written there), in lambdas returned from its
// methods, and in the constructors of its inner classes. An inner class's
// secondary constructor can pass a lambda over the enclosing instance's
// members to its parent as well.
open class Base(val fn: () -> String)

interface Callback {
    fun invoke(): String
}

open class WithCallback(val cb: Callback)

class Outer(val tag: String) {
    inner class Inner : Base {
        constructor() : super({ tag + "!" })
    }

    inner class Defaulted(val fn: () -> String) {
        constructor(unused: Int, fn: () -> String = { tag.uppercase() }) : this(fn)
    }
}

fun build(): String {
    val prefix = "pre"
    var counter = 0
    fun bump(): Int = ++counter

    class Local(k: String) : Base({ prefix + "-" + k + "-" + bump() })

    class Anon : WithCallback(object : Callback {
        override fun invoke() = prefix + "/anon"
    })

    class Holder {
        fun later() = { prefix + "/later" }
        inner class Nested(k: String) : Base({ prefix + "+" + k })
    }

    val local = Local("k")
    val first = local.fn()
    val second = local.fn()
    return listOf(first, second, Anon().cb.invoke(), Holder().later()(), Holder().Nested("n").fn()).joinToString(" ")
}

fun main() {
    println(build())
    println(Outer("t").Inner().fn())
    println(Outer("t").Defaulted(1).fn())
}
