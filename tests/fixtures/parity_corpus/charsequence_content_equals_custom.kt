// contentEquals with a CharSequence of the program's own: lengths first, then
// the characters through get, stopping at the first that differs.
class Letters(private val text: String) : CharSequence {
    var reads = 0
    override val length: Int get() = text.length
    override fun get(index: Int): Char {
        reads++
        return text[index]
    }
    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence =
        Letters(text.substring(startIndex, endIndex))
    override fun toString(): String = text
}

fun main() {
    val abc = Letters("abc")
    println("abc".contentEquals(abc))
    println(abc.contentEquals("abc"))
    println(abc.contentEquals(StringBuilder("abc")))
    println(abc.contentEquals(abc))
    println("abd".contentEquals(abc))
    println("ab".contentEquals(abc))
    println("ABC".contentEquals(abc, ignoreCase = true))
    println("ABC".contentEquals(abc, ignoreCase = false))
    val other = Letters("xbc")
    println(other.contentEquals(Letters("abc")))
    println("reads after a first-character mismatch: ${other.reads}")
    val nothing: CharSequence? = null
    println(nothing.contentEquals(abc))
    println(abc.contentEquals(nothing))
}
