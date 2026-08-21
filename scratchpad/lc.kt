fun main() {
    for (c in listOf('a', '1', '.', '+', '-', 'A')) println("$c isLowerCase=" + c.isLowerCase() + " isLetter=" + c.isLetter())
    println("a123 all = " + "a123".all { it.isLowerCase() })
}
