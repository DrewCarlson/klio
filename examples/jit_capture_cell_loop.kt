// A hot loop that mutates `var`s captured by a nested lambda. Capture makes
// each `var` a boxed cell; the loop body reads and writes them through CellGet/
// CellSet. Exercises the JIT's capture-cell caching (output must match with the
// JIT off or on).
fun main() {
    var sum = 0
    var count = 0
    val snapshot = { Pair(sum, count) }
    var i = 0
    while (i < 50000) {
        sum = sum + i
        count = count + 1
        i = i + 1
    }
    val (s, c) = snapshot()
    println("sum=$sum count=$count snapSum=$s snapCount=$c")
}
