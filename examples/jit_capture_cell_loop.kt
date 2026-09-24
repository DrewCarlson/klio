// A loop that mutates `var`s captured by a nested lambda. A captured `var`
// stays a live, shared reference: the lambda sees every update made to it
// after capture, and reads it back after the loop finishes.
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
