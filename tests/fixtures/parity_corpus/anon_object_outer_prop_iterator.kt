class Wrap<T>(private val sequence: Sequence<T>) : Sequence<T> {
    override fun iterator(): Iterator<T> = object : Iterator<T> {
        val iterator = sequence.iterator()
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): T = iterator.next()
    }
}
fun main() {
    var n = 0
    for (x in Wrap(sequenceOf(1, 2, 3))) n += x
    println(n)
    val w = Wrap(sequenceOf("a", "b"))
    println(w.joinToString("-"))
}
