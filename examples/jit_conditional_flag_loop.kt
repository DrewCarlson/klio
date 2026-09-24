// Loop-carried variables (Boolean, Int, Double, Long) that a loop only ever
// writes, and only on a branch the run may never take. Checks that an
// untaken branch leaves the variable at its original value, and that a
// branch which does fire still overwrites it correctly.
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
