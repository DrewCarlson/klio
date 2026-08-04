const val DIGITS = "ab"
fun main() {
    DIGITS.forEachIndexed { index, char -> println(char) }
    DIGITS.forEach { c -> println(c) }
}
