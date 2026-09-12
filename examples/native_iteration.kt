// `for (x in …)` compiled to C. The loop is the iteration protocol: the
// container answers an iterator, and the loop steps it with `hasNext`/`next`.
// An iterator over a builtin container is a runtime value the interpreter
// already knows how to step, so a compiled program hands those three calls
// back to the same code rather than growing its own iterators.
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
