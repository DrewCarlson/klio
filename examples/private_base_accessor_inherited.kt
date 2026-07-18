// An accessor-only property inherited from a PRIVATE abstract base class
// resolves on the subclass -- the private base registers its accessors
// under its qualified key only, and the hierarchy walk must follow it.

package demo.views

class Store {
    val backing = mutableMapOf(1 to "a", 2 to "b")
    val keys: MutableSet<Int> = KeyView(this)
}

private abstract class BaseView<E>(val store: Store) : MutableSet<E> {
    override val size: Int
        get() = store.backing.size

    override fun clear() {
        store.backing.clear()
    }

    override fun isEmpty() = store.backing.isEmpty()
}

private class KeyView(store: Store) : BaseView<Int>(store) {
    override fun add(element: Int): Boolean = throw UnsupportedOperationException()
    override fun addAll(elements: Collection<Int>): Boolean = throw UnsupportedOperationException()
    override fun iterator(): MutableIterator<Int> = store.backing.keys.iterator()
    override fun remove(element: Int): Boolean = store.backing.remove(element) != null
    override fun removeAll(elements: Collection<Int>): Boolean = false
    override fun retainAll(elements: Collection<Int>): Boolean = false
    override fun contains(element: Int) = store.backing.contains(element)
    override fun containsAll(elements: Collection<Int>): Boolean = elements.all { contains(it) }
}

fun main() {
    val s = Store()
    println("size=" + s.keys.size)
    try {
        s.keys.add(5)
        println("add did not throw")
    } catch (e: UnsupportedOperationException) {
        println("add threw")
    }
    s.keys.clear()
    println("after clear size=" + s.keys.size)
}
