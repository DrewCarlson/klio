// A vararg parameter is the MATERIALIZED array inside its body — with the
// ELEMENT carried (`vararg s: String` is Array<out String>), so forwarding
// it discriminates an overload pair by array kind. The forwarded call also
// names arguments PAST the defaulted startIndex, which must still resolve
// statically and fill the skipped parameter from its default.
private fun CharSequence.ranges(delimiters: CharArray, startIndex: Int = 0, ignoreCase: Boolean = false, limit: Int = 0): List<String> =
    listOf("chars:" + delimiters.size + ":" + startIndex + ":" + ignoreCase + ":" + limit)
private fun CharSequence.ranges(delimiters: Array<out String>, startIndex: Int = 0, ignoreCase: Boolean = false, limit: Int = 0): List<String> =
    listOf("strings:" + delimiters.size + ":" + startIndex + ":" + ignoreCase + ":" + limit)
fun CharSequence.mySplit(vararg delimiters: String, ignoreCase: Boolean = false, limit: Int = 0): String =
    ranges(delimiters, ignoreCase = ignoreCase, limit = limit).first()
fun CharSequence.mySplitC(vararg delimiters: Char, ignoreCase: Boolean = false, limit: Int = 0): String =
    ranges(delimiters, ignoreCase = ignoreCase, limit = limit).first()
fun main() {
    println("a,b".mySplit(",", ";", ignoreCase = true))
    println("a,b".mySplitC(',', limit = 7))
}
