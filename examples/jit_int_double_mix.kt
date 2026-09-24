// A loop mixing an Int counter with Double arithmetic via `i.toDouble()`.
fun main() {
    val n = 100000
    var sum = 0.0
    var i = 0
    while (i < n) {
        sum = sum + i.toDouble() * 0.5 - 1.0
        i = i + 1
    }
    println(sum)
}
