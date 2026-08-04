fun main() {
    val infiniteSeq = generateSequence(0) { it + 1 }
    val size = 7
    val seq = infiniteSeq.take(7)
    val result2 = seq.windowed(2, 3) { it.joinToString("") }
    println(result2.toList())
    println(seq.windowed(2, size).single())
    println(seq.windowed(size + 1, 1).none())
    println(emptySequence<String>().windowed(3, 2).none())
    println("ok")
}
