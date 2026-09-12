// A range held as a value. `1..5` is not a loop, it is a progression: a runtime
// value with a start, an inclusive end and a signed step, and the bounds it
// answers are the ones the interpreter computes. Iterating one steps it through
// the same iterator any other container gives.
fun main() {
    val r = 1..5
    var sum = 0
    for (x in r) sum = sum + x
    println(sum)
    println(r.first)
    println(r.last)
    println(r.step)

    // A half-open range ends one before its bound.
    val half = 0..<4
    var count = 0
    for (x in half) count = count + 1
    println(count)

    // A character range counts code units.
    val letters = 'a'..'e'
    var line = ""
    for (ch in letters) line = line + ch
    println(line)

    // A Long progression keeps its width.
    val wide = 1L..3L
    var total = 0L
    for (x in wide) total = total + x
    println(total)
}
