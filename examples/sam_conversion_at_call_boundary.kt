// A lambda passed where a `fun interface` is expected IS an instance of that
// interface — Kotlin converts at the call boundary, not at the use. So the
// value the callee receives answers `is Iface`, carries the interface's
// identity, and extensions declared on the interface apply to it.
//
// Run with: klio run examples/sam_conversion_at_call_boundary.kt

fun interface Handler {
    fun handle(v: Int): String
}

fun interface Predicate {
    fun test(v: Int): Boolean
}

// An extension on the interface: it applies only to a real instance.
fun Handler.twice(v: Int): String = handle(v) + handle(v)
fun Predicate.negate(v: Int): Boolean = !test(v)

fun describe(h: Handler): String = "" + (h is Handler) + "/" + h.handle(1) + "/" + h.twice(2)

class Box(val tag: String) {
    fun via(h: Handler): String = tag + ":" + (h is Handler) + ":" + h.twice(3)
}

// A parameter that is NOT a fun interface keeps the plain function type.
fun plain(f: (Int) -> String): String = f(9)

fun main() {
    // A lambda literal at the call.
    println("literal  = " + describe { v -> "<$v>" })
    // Through a member.
    println("member   = " + Box("b").via { v -> "[$v]" })
    // The explicit constructor form agrees.
    println("explicit = " + describe(Handler { v -> "{$v}" }))

    // A lambda held in a variable converts at the call, not at creation.
    val f: (Int) -> String = { v -> "($v)" }
    println("variable = " + describe(f))

    // A second interface with the same shape stays distinct.
    val p = Predicate { v -> v > 0 }
    println("predicate= " + (p is Predicate) + "/" + (p is Handler) + "/" + p.negate(1))
    println("inline p = " + describe { v -> "" + Predicate { n -> n > v }.test(3) })

    // A plain function type is not converted.
    println("plain    = " + plain { v -> "p$v" })

    // Passing the same lambda to two different interfaces converts per call.
    val shared: (Int) -> String = { v -> "s$v" }
    println("reuse    = " + describe(shared) + " " + Box("x").via(shared))
}
