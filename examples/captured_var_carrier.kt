// Captured `var` carrier: a mutable `var` mutated inside a lambda must
// round-trip identically no matter how the closure is invoked — called
// directly, passed to a stdlib higher-order function, or captured across a
// coroutine launch/suspend. Each section prints the final value so the
// carrier can be checked to be uniform across all three paths.
import kotlinx.coroutines.*

// A user higher-order function that invokes the lambda directly (the
// `callValue` path, not a stdlib HOF).
fun callTimes(n: Int, f: () -> Unit) {
    var i = 0
    while (i < n) {
        f()
        i = i + 1
    }
}

// An inline higher-order function. Its body's own `var` (boxed here as a
// shared cell) and the user lambda it splices both write the same captured
// counter, so the splice boundary must carry the write precisely.
inline fun runAndCount(times: Int, block: (Int) -> Unit): Int {
    var invoked = 0
    var k = 0
    while (k < times) {
        block(k)
        invoked = invoked + 1
        k = k + 1
    }
    return invoked
}

fun main() = runBlocking {
    // (a) Captured var mutated by a lambda called directly.
    var direct = 0
    val bump = { direct = direct + 1 }
    bump(); bump(); bump()
    callTimes(2, bump)
    println("direct=$direct")

    // (a') Sibling closures sharing one captured var: one writes, one reads.
    var shared = 0
    val inc = { shared = shared + 10 }
    val read = { shared }
    inc(); inc()
    println("shared=${read()}")

    // (b) Captured var mutated inside a stdlib HOF lambda (forEach / fold).
    var hof = 0
    listOf(1, 2, 3, 4).forEach { hof = hof + it }
    println("hof=$hof")

    var folded = 0
    listOf(5, 10, 15).fold(0) { acc, x ->
        folded = folded + x
        acc + x
    }
    println("folded=$folded")

    // (b') Captured var written from an inline HOF that also writes its own
    // body var across the splice boundary.
    var acc = 0
    val invocations = runAndCount(3) { step -> acc = acc + step }
    println("acc=$acc invocations=$invocations")

    // A captured cell first mentioned by interpolation in a branch that is
    // not taken must still dominate a read from the other branch.
    var branchCount = 0
    val branchRead: (Boolean) -> Int = { renderMessage ->
        branchCount++
        if (renderMessage) "count=$branchCount".length
        else listOf(10, 20)[branchCount - 1]
    }
    println("branch=${branchRead(false)} count=$branchCount")

    // (c) Captured var mutated inside a coroutine launch across a suspend.
    var suspended = 0
    val jobs = ArrayList<Job>()
    var j = 0
    while (j < 3) {
        val delayMs = (j + 1) * 10L
        val add = (j + 1) * 100
        jobs.add(launch {
            delay(delayMs)
            suspended = suspended + add
        })
        j = j + 1
    }
    for (job in jobs) job.join()
    println("suspended=$suspended")

    // (c') A captured var written both before and after a suspension point in
    // the same coroutine body, to prove the carrier survives the park.
    var crossed = 0
    val job = launch {
        crossed = crossed + 1
        delay(5L)
        crossed = crossed + 1
    }
    job.join()
    println("crossed=$crossed")
}
