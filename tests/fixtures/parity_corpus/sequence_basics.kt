fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    val seq = xs.asSequence().map { it * 10 }.filter { it > 20 }
    println(seq.toList())
    println(seq.count())
    println(seq.first())
    println(seq.last())
    println(sequenceOf(1, 2, 3).toList())
}
