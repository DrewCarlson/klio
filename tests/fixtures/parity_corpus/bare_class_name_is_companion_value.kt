// A bare class / interface name used as a *value* is its companion
// object (Kotlin: `val x: Any = Foo` is `Foo.Companion`) — for a
// default-named and an explicitly-named companion, and an interface.
// Construction, `::class`, and qualified member access take their own
// paths; a class without a companion and an `object` singleton are
// unchanged.

class C {
    companion object
}

class D {
    companion object Named
}

interface I {
    companion object Key
}

object O

fun main() {
    val a: Any = C
    println(a === C.Companion)
    val b: Any = D
    println(b === D.Named)
    val i: Any = I
    println(i === I.Key)
    val o: Any = O
    println(o === O)

    val xs = listOf<Any>(C, D, I, O)
    println(xs[0] === C.Companion)
    println(xs[1] === D.Named)
    println(xs[2] === I.Key)
    println(xs[3] === O)

    println(C === C)
    println(D.Named === D.Named)
    println(C() is C)
    println(C() !== C())
}
