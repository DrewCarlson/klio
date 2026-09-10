// Calling a method on an object held OUTSIDE a loop — the most ordinary shape
// in Kotlin — used to defeat the loop tier twice over. The receiver register
// had no in-body instruction to infer its type from, so the loop bailed as
// untyped; and a static call to anything with a receiver parameter was refused
// outright. `c.bump(1)` lowers to exactly that: a static call with the receiver
// moved into argument 0.
//
// Both gates are now openings rather than refusals. The receiver's field buffer
// is already cached at loop entry for native field access, so the call reuses
// it and needs no per-iteration guard.
//
// Output must match with the JIT off (--opt safe) or on, and with direct calls
// disabled (KLIO_FJ_DIRECT=0).
class Counter {
    var n = 0
    var hits = 0
    fun bump(k: Int) { n += k }
    fun tally() { hits = hits + 1 }
    fun value(): Int = n
}

fun main() {
    val c = Counter()
    var i = 0
    while (i < 200_000) {
        c.bump(2)
        c.tally()
        i += 1
    }
    println("n=" + c.value() + " hits=" + c.hits)
}
