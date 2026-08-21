package demo

fun Char.isLowerCase(): Boolean = lowercaseChar() == this

fun main() {
    println("a123 all = " + "a123".all { it.isLowerCase() })
    println("'1' = " + '1'.isLowerCase())
}
