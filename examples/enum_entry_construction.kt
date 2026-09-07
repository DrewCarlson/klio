// An enum entry with a body may name itself while it is being constructed:
// in its own initializers and in the constructors and delegations of its
// inner classes the name is the instance under construction, as kotlinc
// binds it. Entry constructors take `vararg` parameters like any
// constructor: an entry supplying nothing gets the empty array, through the
// primary constructor or a secondary one, and a subclass header omitting a
// parent's vararg does the same.
interface Greeter {
    fun greet(): String
}

abstract class Holder(val g: Greeter)

enum class Kind : Greeter {
    PLAIN {
        inner class Wrapper : Holder(PLAIN)

        val wrapper = Wrapper()
        val viaCall = PLAIN.greet()

        inner class Forward : Greeter by PLAIN

        val forward = Forward()

        override fun greet() = "plain"

        override fun report() = "${wrapper.g.greet()} $viaCall ${forward.greet()} same=${wrapper.g === this}"
    };

    abstract fun report(): String
}

enum class Flags(vararg xs: Int) {
    NONE, ONE(7), SOME(1, 2) {
        fun extra() = "body"
    };

    val bits = xs
}

enum class Sized(val x: Int, val str: String) {
    DEFAULT, PAIR(2, "pair");

    constructor(vararg xs: Int) : this(xs.size + 42, "vararg")
}

class Box(val n: Int, val tag: String) {
    constructor(vararg xs: Int) : this(xs.size, "packed")
}

open class Parent(vararg xs: Int) {
    val count = xs.size
}

class NoArgs : Parent()

class TwoArgs : Parent(4, 5)

fun main() {
    println(Kind.PLAIN.report())
    println(Flags.entries.map { it.bits.size })
    println(Flags.SOME.bits.toList())
    println("${Sized.DEFAULT.x} ${Sized.DEFAULT.str}")
    println("${Sized.PAIR.x} ${Sized.PAIR.str}")
    println("${Box().n} ${Box().tag}")
    println("${Box(5, 6, 7).n} ${Box(5, 6, 7).tag}")
    println("${Box(1, "x").n} ${Box(1, "x").tag}")
    println("${NoArgs().count} ${TwoArgs().count}")
}
