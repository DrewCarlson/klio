// `Int.toLong()`, `xor`, and `shr` combined in a loop, plus a separate loop
// doing `Int.toDouble()` conversion and division.
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
