fun <T> List<T>.runA(): List<T> {
    val iterator = listIterator(size)
    return ArrayList<T>(1).apply {
        while (iterator.hasPrevious()) add(iterator.previous())
    }
}
inline fun <T> List<T>.runB(): List<T> {
    val iterator = listIterator(size)
    return ArrayList<T>(1).apply {
        while (iterator.hasPrevious()) add(iterator.previous())
    }
}
fun main() { println(listOf(1,2).runA()); println(listOf(1,2).runB()) }
