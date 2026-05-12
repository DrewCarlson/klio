fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6, 7)
    val a = xs.chunked(size = 3)
    println(a)
    val b = "abcdefg".chunked(size = 2)
    println(b)
}
