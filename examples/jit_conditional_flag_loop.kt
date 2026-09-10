// Loop-carried variables that a hot loop only ever WRITES, and only on a branch
// the run may never take. The loop JIT keeps scalars in slots and writes every
// written register back when the loop exits, so each of these has to start from
// its live-in value: an unseeded slot reports zero, turning an untouched `true`
// into `false` and an untouched running total into 0.
// Output must match with the JIT off (--opt safe) or on (default).
fun main() {
    val bytes = ByteArray(500) { (it % 64).toByte() }
    val ints = IntArray(500) { it % 64 }

    var ordered = true
    for (i in 0 until 500) {
        if (bytes[i].toInt() != i % 64) ordered = false
    }
    println("ordered=$ordered")

    var intsOrdered = true
    for (i in 0 until 500) {
        if (ints[i] != i % 64) intsOrdered = false
    }
    println("intsOrdered=$intsOrdered")

    var sawBig = false
    for (i in 0 until 500) {
        if (ints[i] > 100) sawBig = true
    }
    println("sawBig=$sawBig")

    var lastOdd = -7
    for (i in 0 until 500) {
        if (ints[i] > 1000) lastOdd = i
    }
    println("lastOdd=$lastOdd")

    var scale = 2.5
    for (i in 0 until 500) {
        if (ints[i] > 1000) scale = 9.0
    }
    println("scale=$scale")

    var total = 0L
    for (i in 0 until 500) {
        if (ints[i] > 1000) total = 1L
    }
    println("total=$total")

    // The branch DOES fire: the write must still win over the seeded value.
    var hit = false
    for (i in 0 until 500) {
        if (ints[i] == 63) hit = true
    }
    println("hit=$hit")
}
