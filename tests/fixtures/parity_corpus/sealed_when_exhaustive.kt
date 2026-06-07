// Sealed-`when` covered without an `else` branch: every concrete subclass
// is named, so T0019 must not fire and runtime never hits
// NoWhenBranchMatchedException.

sealed class Op
class Add(val a: Int, val b: Int): Op()
class Mul(val a: Int, val b: Int): Op()
class Neg(val v: Int): Op()

fun eval(op: Op): Int = when (op) {
    is Add -> op.a + op.b
    is Mul -> op.a * op.b
    is Neg -> -op.v
}

fun main() {
    println(eval(Add(2, 3)))
    println(eval(Mul(4, 5)))
    println(eval(Neg(7)))
}
