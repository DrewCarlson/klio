// Char arithmetic (Char-Char -> Int code distance; Char +/- Int ->
// Char), String.regionMatches, and the kotlin.text bit-count helpers.
fun parseTwo(s: String): Int = (s[0] - '0') * 10 + (s[1] - '0')

fun main() {
    println('9' - '0')
    println('a' + 2)
    println('z' - 5)
    println(parseTwo("37"))
    println("hello world".regionMatches(6, "world", 0, 5))
    println("ABCxx".regionMatches(0, "abc", 0, 3, ignoreCase = true))
    println("abc".regionMatches(0, "abd", 0, 3))
    println(255.countLeadingZeroBits())
    println(255.countOneBits())
    println(1024.countTrailingZeroBits())
    println(1L.countLeadingZeroBits())
}
