// A JIT-compiled counted loop dispatching a VIRTUAL member call per
// iteration (interface-typed receiver -> slot dispatch through the loop
// trampoline). The tier-up must keep dynamic dispatch exact for both
// receiver classes and preserve the callee's field effects — the virtual
// site carries no class guard, so the same compiled loop body must serve
// either receiver correctly.
interface Acc { fun add(v: Int): Int }
class ByOne : Acc { var t = 0; override fun add(v: Int): Int { t += v; return t } }
class ByTwo : Acc { var t = 0; override fun add(v: Int): Int { t += 2 * v; return t } }

fun drive(a: Acc, reps: Int): Int {
    var last = 0
    var i = 0
    while (i < reps) { last = a.add(1); i += 1 }
    return last
}

fun main() {
    val x = ByOne()
    val y = ByTwo()
    println("one=" + drive(x, 500) + " two=" + drive(y, 500) + " tx=" + x.t + " ty=" + y.t)
}

//> one=500 two=1000 tx=500 ty=1000
