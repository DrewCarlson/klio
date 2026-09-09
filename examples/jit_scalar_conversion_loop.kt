// `i.toLong()` on a scalar lowers to a virtual call and `xor`/`shr` to member
// calls, so both used to be registered as trampoline sites: a host callback per
// iteration to do two instructions' worth of work, which made the compiled loop
// SLOWER than the interpreter. The emitter has always had an inline form for
// them; the site passes just did not recognize the call spelling.
//
// Output must match with the JIT off (--opt safe) or on.
fun main() {
    var i = 0
    var acc = 0L
    while (i < 400_000) {
        acc += (i.toLong() * 3) xor (i.toLong() shr 2)
        i += 1
    }
    var d = 0.0
    var j = 0
    while (j < 100_000) {
        d += j.toDouble() / 4.0
        j += 1
    }
    println("acc=" + acc + " d=" + d)
}
