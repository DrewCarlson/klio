// Kotlin's String.compareTo and the < / <= / > / >= operators on String
// compare in UTF-16 code units. For BMP-only strings this agrees with a
// UTF-8 byte comparison, but supplementary characters (above U+FFFF)
// diverge: 😀 (U+1F600) starts with high surrogate D83D in UTF-16, so it
// sorts before the private-use code point U+E000; in UTF-8 the 4-byte
// encoding F0 9F 98 80 would sort after.

fun sign(n: Int): Int = if (n < 0) -1 else if (n > 0) 1 else 0

fun main() {
    val grin = "😀"          // U+1F600 😀
    val clef = "𝄞"          // U+1D11E 𝄞
    val pua = ""
    val highBmp = ""

    println(sign(grin.compareTo(pua)))
    println(sign(clef.compareTo(highBmp)))
    println(sign("abc".compareTo("abd")))
    println(sign("abc".compareTo("abc")))
    println(sign("abd".compareTo("abc")))
    println(sign("".compareTo("a")))
    println(sign(grin.compareTo(grin)))

    println(grin < pua)
    println(grin > pua)
    println(grin <= pua)
    println(grin >= pua)
    println(clef < highBmp)
    println("abc" < "abd")
    println("abd" > "abc")
    println("abc" <= "abc")
    println("abc" >= "abc")

    val sorted = listOf(grin, highBmp, "a").sortedBy { it }
    println(sorted)

    val sortedNatural = listOf(grin, pua, "a").sortedWith(naturalOrder<String>())
    println(sortedNatural)

    val sortedReverse = listOf(grin, pua, "a").sortedWith(reverseOrder<String>())
    println(sortedReverse)
}
