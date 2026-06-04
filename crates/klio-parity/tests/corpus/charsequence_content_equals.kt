fun main() {
    println("abc".contentEquals("abc"))
    println("abc".contentEquals("abd"))
    println("abc".contentEquals(StringBuilder("abc")))
    println("abc".contentEquals(StringBuilder("xyz")))
    val sb = StringBuilder("hello")
    println(sb.contentEquals("hello"))
    println(sb.contentEquals(StringBuilder("hello")))
}
