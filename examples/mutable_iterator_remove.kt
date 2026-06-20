// MutableIterator.remove() over a MutableList writes through to the source list
// (Kotlin semantics): the iterator shares the list's live backing. Exercises the
// shared-backing list representation's write-through removal.
fun main() {
    val xs = mutableListOf(1, 2, 3, 4, 5, 6)
    val it = xs.iterator()
    while (it.hasNext()) {
        val v = it.next()
        if (v % 2 == 0) it.remove()
    }
    println(xs)
    println(xs.size)
}
