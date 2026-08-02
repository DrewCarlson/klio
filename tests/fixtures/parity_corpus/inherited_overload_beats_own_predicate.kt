open class Store {
    val data = mutableListOf(0, 1, 2, 3, 4, 5)
    fun removeAll(elements: List<Int>): Boolean {
        var changed = false
        for (e in elements) if (data.remove(e)) changed = true
        return changed
    }
}

class FilterStore : Store() {
    fun removeAll(predicate: (Int) -> Boolean): Boolean {
        var changed = false
        val iter = data.iterator()
        while (iter.hasNext()) {
            if (predicate(iter.next())) {
                iter.remove()
                changed = true
            }
        }
        return changed
    }
}

fun main() {
    val s = FilterStore()
    s.removeAll(listOf(2, 4))
    println(s.data)
    s.removeAll { it > 3 }
    println(s.data)
}
