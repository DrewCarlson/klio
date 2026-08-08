// kotlinc compiles `String.compareTo` to the JVM's, which is the code-unit
// difference at the first mismatch and the length difference when one string
// is a prefix of the other.
fun main() {
    println("a".compareTo("c"))
    println("c".compareTo("a"))
    println("abc".compareTo("abc"))
    println("ab".compareTo("abcd"))
    println("abcd".compareTo("ab"))
    println("".compareTo("abc"))
    println("A".compareTo("a"))
    println("A".compareTo("a", ignoreCase = true))
    println("Hello".compareTo("hello", ignoreCase = true))
    println(listOf("pear", "apple", "fig").sorted())
    println("abc" < "abd")
}
