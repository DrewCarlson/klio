// Kotlin orders strings by UTF-16 code units. Supplementary characters
// (above U+FFFF) are emitted as surrogate pairs, and the high surrogate
// D800-DBFF sorts before the U+E000-U+FFFF private-use range. This
// example prints BMP-only comparisons (which agree with raw byte order)
// alongside a supplementary-character pair where UTF-16 and UTF-8 byte
// ordering disagree.

fun sign(n: Int): Int = if (n < 0) -1 else if (n > 0) 1 else 0

fun main() {
    println(sign("apple".compareTo("banana")))
    println(sign("banana".compareTo("apple")))
    println(sign("apple".compareTo("apple")))

    val grin = "😀"
    val pua = ""
    println(sign(grin.compareTo(pua)))
    println(grin < pua)
    println(grin > pua)

    val words = listOf("pear", "apple", "kiwi")
    println(words.sortedBy { it })

    val mixed = listOf(grin, pua, "a")
    println(mixed.sortedBy { it })
}
