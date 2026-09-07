// A call spelled like a constructor resolves to the companion object's
// `invoke` when no constructor or same-named function fits the arguments,
// including an `invoke` the companion inherits; an enum entry used as a
// callee (`Op.ADD(2, 3)`, or `ADD(4, 5)` through an import) calls the
// entry's `invoke`, whether a member or an extension.
import Op.ADD

class Meters(val value: Int) {
    companion object {
        operator fun invoke(text: String): Meters = Meters(text.removeSuffix("m").toInt())
    }
    override fun toString() = "${value}m"
}

interface Parser {
    operator fun invoke(s: String): Int = s.toInt() * 2
}

class Doubler {
    companion object : Parser
}

enum class Op {
    ADD, MUL;
    operator fun invoke(a: Int, b: Int): Int = when (this) {
        ADD -> a + b
        MUL -> a * b
    }
}

enum class Greeting { HI, BYE }
operator fun Greeting.invoke(who: String) = "${name.lowercase()} $who"

fun main() {
    println(Meters(5))
    println(Meters("12m"))
    println(Doubler("21"))
    println(Op.ADD(2, 3))
    println(Op.MUL(2, 3))
    println(ADD(4, 5))
    println(Greeting.HI("Ann"))
    println(Greeting.BYE("Bob"))
}
