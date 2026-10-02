// `for (x in …)` compiled to C. A loop over a builtin list, set, array or
// string reads it by position through the runtime the interpreter uses, so a
// compiled program grows no iteration code of its own; any other iterable is
// stepped through its iterator's `hasNext`/`next`.
fun main() {
    val words = listOf("alpha", "beta", "gamma")
    for (w in words) println(w)

    // A mutable list iterates over what it holds at the moment the loop
    // starts, including whatever was appended before then.
    val ns = mutableListOf(1, 2, 3)
    ns.add(4)
    var total = 0
    for (n in ns) total = total + n
    println(total)

    // A primitive array iterates from its own storage, and its elements keep
    // their machine type through the loop.
    val arr = intArrayOf(5, 6, 7)
    var product = 1
    for (a in arr) product = product * a
    println(product)

    // Nested loops, each with its own iterator.
    var pairs = 0
    for (w in words) {
        for (n in ns) pairs = pairs + 1
    }
    println(pairs)

    // A range loop needs no iterator at all: it counts.
    var ramp = 0
    for (i in 0 until 5) ramp = ramp + i
    for (i in 5 downTo 1) ramp = ramp + i
    for (i in 0..10 step 2) ramp = ramp + i
    println(ramp)
}
