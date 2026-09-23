// The two numbers `plans/resolved-interpreter.md` is aimed at: what one
// trivial register-to-register instruction costs, and what the cheapest
// activation costs.
//
// Both are measured as a DIFFERENCE between two loops that are identical but
// for the thing being measured, so loop overhead, the clock call, the
// induction variable and the surrounding frame all cancel. Measuring either
// one directly would be measuring the loop.
//
// Each measurement runs several times and keeps the minimum: the minimum is
// the run least disturbed by the collector, the scheduler and the machine,
// and the quantity here is a floor, not an average.

import kotlin.system.measureNanoTime

const val ITERS = 400_000
const val REPS = 7

/// One trivial instruction in the body: a register-to-register integer op.
///
/// Addition, not `xor`: two `xor`s of the same register cancel, so a folding
/// pass could delete the very thing being timed and the benchmark would read
/// as fast rather than as wrong.
fun narrowLoop(n: Int): Int {
    var a = 1
    var i = 0
    while (i < n) {
        a = a + i
        i = i + 1
    }
    return a
}

/// Sixteen of them, so the difference is fifteen extra instructions per
/// iteration and nothing else.
fun wideLoop(n: Int): Int {
    var a = 1
    var i = 0
    while (i < n) {
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        a = a + i
        i = i + 1
    }
    return a
}

/// The cheapest callee that is actually CALLED. A one-expression `fun f(x) = x`
/// is spliced at lowering and costs no activation at all — the first version
/// of this benchmark measured 1.07 ns and 49 frame pushes for 2.8 million
/// intended calls, which is the interpreter being right and the measurement
/// being wrong. Self-recursion blocks the splice; the recursive arm never
/// runs, so what is left is the activation and nothing else.
fun identity(x: Int): Int = if (x < 0) identity(x + 1) else x

fun callLoop(n: Int): Int {
    var a = 0
    var i = 0
    while (i < n) {
        a = a + identity(i)
        i = i + 1
    }
    return a
}

/// The same loop with the call's work done in place, so the difference is one
/// activation per iteration.
fun inlineLoop(n: Int): Int {
    var a = 0
    var i = 0
    while (i < n) {
        a = a + i
        i = i + 1
    }
    return a
}

fun minOf(runs: List<Long>): Long {
    var m = runs[0]
    for (r in runs) if (r < m) m = r
    return m
}

fun measure(label: String, wide: Boolean, calls: Boolean, per: Int) {
    var sink = 0
    // Warm every path before timing: the first execution of a body fills site
    // memos and tier verdicts, and that cost belongs to neither number.
    repeat(2) {
        sink = sink + if (calls) callLoop(1000) else if (wide) wideLoop(1000) else narrowLoop(1000)
        sink = sink + if (calls) inlineLoop(1000) else narrowLoop(1000)
    }
    val hot = mutableListOf<Long>()
    val base = mutableListOf<Long>()
    for (r in 1..REPS) {
        hot.add(measureNanoTime { sink = sink + (if (calls) callLoop(ITERS) else wideLoop(ITERS)) })
        base.add(measureNanoTime { sink = sink + (if (calls) inlineLoop(ITERS) else narrowLoop(ITERS)) })
    }
    val delta = minOf(hot) - minOf(base)
    val each = delta.toDouble() / (ITERS.toDouble() * per.toDouble())
    println("$label ${fmt(each)} ns  (delta ${delta / 1000}us over ${ITERS * per} ops, sink=${sink and 1})")
}

fun fmt(v: Double): String {
    val hundredths = (v * 100.0).toLong()
    return "${hundredths / 100}.${(hundredths % 100).toString().padStart(2, '0')}"
}

fun main() {
    measure("trivial-instruction", wide = true, calls = false, per = 15)
    measure("cheapest-activation", wide = false, calls = true, per = 1)
}
