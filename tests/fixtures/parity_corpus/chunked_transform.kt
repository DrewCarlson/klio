fun main() {
    println(listOf(1, 2, 3, 4, 5).chunked(2) { it.sum() })
    println(listOf(1, 2, 3, 4, 5, 6).chunked(3) { it.joinToString("-") })
    println("abcdefg".chunked(3) { it.toString().uppercase() })
    println("abcdefg".chunked(3) { it.length })
    println("abcdefg".chunked(3))
    println(listOf(10, 20, 30, 40).chunked(2))
    println((1..10).toList().chunked(4) { it.average() })
}
