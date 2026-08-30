// The seam method tier: a hot member-dispatched field-arithmetic body
// compiles DEOPT-FREE (no calls, no division, NN-proven reads) and serves
// at the call seam with no frame at all. The compiled body is guarded on
// the exact receiver class — a subclass instance reaching the same method
// must decline to the interpreter and stay exact, and the receiver's field
// effects must be identical either way.
open class Ctr(var t: Int) {
    fun bump(v: Int): Int {
        t = t + v
        return t
    }
}
class Sub(t0: Int) : Ctr(t0)

fun drive(c: Ctr, reps: Int): Int {
    var last = 0
    var i = 0
    while (i < reps) {
        last = c.bump(2)
        i += 1
    }
    return last
}

fun main() {
    val a = Ctr(0)
    val b = Sub(1000)
    println("a=" + drive(a, 500) + " b=" + drive(b, 500) + " ta=" + a.t + " tb=" + b.t)
}

//> a=1000 b=2000 ta=1000 tb=2000
