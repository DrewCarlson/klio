// MM11 — no torn / out-of-thin-air value under a real data race.
// Kotlin's memory model permits *lost updates* on a racy `var` but
// never corruption: a racing read still observes some value that was
// actually written, never a torn or out-of-thin-air one (the MM1/MM3
// floor holds even for racing programs).
//
// Two parts:
//   * Deterministic DRF section — N threads each write only their
//     own array slot (no sharing => no race). Joined, the sum is
//     fixed: 0+1+...+(N-1) = 28 for N=8. This is the `//> ` output,
//     keeping stdout deterministic for the gate.
//   * Racy section — the same N threads each do `iters` *fully
//     unsynchronized* `shared++` on one shared `var` (a genuine data
//     race). Lost updates are allowed, so the only asserted property
//     is the no-OOTA/no-tearing invariant: the final value is an
//     integer in [N, N*iters]. That is checked *inside* the program
//     with `require(...)`, so a violation throws and changes the
//     output (failing the gate); a correct run prints nothing extra.
//
// The program must (a) never panic and (b) print exactly the
// deterministic DRF result.
//> 28
import kotlin.concurrent.thread

fun main() {
    val n = 8
    val iters = 1000

    // --- Deterministic, data-race-free section ---
    val slots = IntArray(n)
    val drf = ArrayList<Thread>()
    for (i in 0 until n) {
        drf.add(thread { slots[i] = i })
    }
    for (t in drf) t.join()
    var drfSum = 0
    for (v in slots) drfSum += v

    // --- Genuinely racy section (unsynchronized shared counter) ---
    var shared = 0
    val racers = ArrayList<Thread>()
    for (i in 0 until n) {
        racers.add(thread {
            repeat(iters) { shared = shared + 1 }
        })
    }
    for (t in racers) t.join()

    // Lost updates allowed; corruption / out-of-thin-air is not.
    // Floor: at least one increment from one thread survives; ceiling:
    // no more than every increment. Any value outside [n, n*iters]
    // would be a torn or fabricated read.
    require(shared in n..(n * iters)) {
        "out-of-thin-air / torn racy value: $shared"
    }

    // Only the deterministic part reaches stdout.
    println(drfSum)
}
