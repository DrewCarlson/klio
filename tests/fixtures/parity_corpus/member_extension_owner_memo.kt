// A member-extension resolution depends on the enclosing receivers, not on
// the explicit receiver alone: the same call site must reach a different
// owner's body when the surrounding `with` binds a different one, and must
// still find the owner when it sits deeper in the chain.

interface Arg {
    val n: Int
}

class ArgImpl(override val n: Int) : Arg

abstract class Op(val tag: String) {
    abstract fun Arg.exec(): String
}

class OpA : Op("A") {
    override fun Arg.exec(): String = tag + n
}

class OpB : Op("B") {
    override fun Arg.exec(): String = "b" + tag + n
}

fun run(op: Op, a: Arg): String = with(op) { a.exec() }

class Outer(private val op: Op) {
    fun deep(a: Arg): String = with(op) { with("ignored") { a.exec() } }
}

fun main() {
    val a = ArgImpl(7)
    val alternating = StringBuilder()
    repeat(3) {
        alternating.append(run(OpA(), a)).append(' ')
        alternating.append(run(OpB(), a)).append(' ')
    }
    println(alternating.toString().trim())
    println(Outer(OpA()).deep(a) + " " + Outer(OpB()).deep(a))
}
