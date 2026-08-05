// A bare call inside a member body is a member call on the implicit
// receiver, and its declared return types the local it initializes.
class Feed(private val rows: MutableList<String>) {
    fun rowsIterator(): MutableListIterator<String> = rows.listIterator()
    fun head(): String = rows[0]

    fun render(): String {
        val it0 = rowsIterator()
        val sb = StringBuilder()
        while (it0.hasNext()) {
            sb.append(it0.next().uppercase())
            if (it0.hasNext()) sb.append(",")
        }
        val first = head()
        sb.append("|").append(first.length.toString())
        return sb.toString()
    }
}

fun main() {
    println(Feed(mutableListOf("ab", "cd")).render())
    println(listOf(1, 2, 3, 4).takeLastWhile { it > 2 })
}
