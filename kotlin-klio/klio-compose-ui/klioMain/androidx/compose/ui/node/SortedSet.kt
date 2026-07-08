// A sorted set over the depth-comparator the layout remeasure queue uses.
package androidx.compose.ui.node

internal actual class SortedSet<E> actual constructor(private val comparator: Comparator<in E>) {
    private val items = mutableListOf<E>()
    actual fun add(element: E): Boolean {
        if (items.contains(element)) return false
        var i = 0
        while (i < items.size && comparator.compare(items[i], element) < 0) i++
        items.add(i, element)
        return true
    }
    actual fun remove(element: E): Boolean = items.remove(element)
    actual fun first(): E = items.first()
    actual fun contains(element: E): Boolean = items.contains(element)
    actual fun isEmpty(): Boolean = items.isEmpty()
}
