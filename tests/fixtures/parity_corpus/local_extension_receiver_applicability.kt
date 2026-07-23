fun main() {
    fun String.contentEquals(other: String, ignoreCase: Boolean): Boolean = false

    println(null.contentEquals(null, ignoreCase = true))
    println("a".contentEquals("a", ignoreCase = true))
}
