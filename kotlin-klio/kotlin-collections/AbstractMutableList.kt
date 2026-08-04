/*
 * klio-authored `actual` skeletal mutable collections.
 *
 * The upstream tree offers these only as JS / native-wasm platform sources,
 * which klio does not consume: the interpreter is its own platform, and a
 * browser or wasm backend's implementation choices are not ours to inherit.
 * The behaviour is Kotlin's documented contract for each class — structural
 * modification counting with fail-fast iterators, index checks through
 * `AbstractList`, and `SubList` as a live view onto its parent.
 */
package kotlin.collections

public actual abstract class AbstractMutableList<E> protected actual constructor() : AbstractMutableCollection<E>(), MutableList<E> {

    /**
     * The number of times this list is structurally modified. Iterators
     * compare against it to detect concurrent modification.
     */
    protected actual var modCount: Int = 0

    abstract override fun add(index: Int, element: E): Unit
    @IgnorableReturnValue abstract override fun removeAt(index: Int): E
    @IgnorableReturnValue abstract override fun set(index: Int, element: E): E

    @IgnorableReturnValue
    override actual fun add(element: E): Boolean {
        add(size, element)
        return true
    }

    @IgnorableReturnValue
    override actual fun addAll(index: Int, elements: Collection<E>): Boolean {
        AbstractList.checkPositionIndex(index, size)

        var i = index
        var changed = false
        for (e in elements) {
            add(i++, e)
            changed = true
        }
        return changed
    }

    override actual fun clear() {
        removeRange(0, size)
    }

    @IgnorableReturnValue
    override actual fun removeAll(elements: Collection<E>): Boolean = removeAll { it in elements }

    @IgnorableReturnValue
    override actual fun retainAll(elements: Collection<E>): Boolean = removeAll { it !in elements }

    override actual fun iterator(): MutableIterator<E> = IteratorImpl()

    override actual fun contains(element: E): Boolean = indexOf(element) >= 0

    override actual fun indexOf(element: E): Int = indexOfFirst { it == element }

    override actual fun lastIndexOf(element: E): Int = indexOfLast { it == element }

    override actual fun listIterator(): MutableListIterator<E> = listIterator(0)
    override actual fun listIterator(index: Int): MutableListIterator<E> = ListIteratorImpl(index)

    override actual fun subList(fromIndex: Int, toIndex: Int): MutableList<E> = SubList(this, fromIndex, toIndex)

    /**
     * Removes `[fromIndex, toIndex)` from this list.
     *
     * Through the list's own iterator: a subclass that overrides
     * `listIterator` does so because walking its backing is cheaper than
     * re-entering it per index, and a persistent-vector builder's cursor is
     * exactly that — repeated `removeAt` re-descends its trie every time.
     */
    protected actual open fun removeRange(fromIndex: Int, toIndex: Int) {
        val iterator = listIterator(fromIndex)
        repeat(toIndex - fromIndex) {
            val _ = iterator.next()
            iterator.remove()
        }
    }

    override fun equals(other: Any?): Boolean {
        if (other === this) return true
        if (other !is List<*>) return false

        return AbstractList.orderedEquals(this, other)
    }

    override fun hashCode(): Int = AbstractList.orderedHashCode(this)

    private open inner class IteratorImpl : MutableIterator<E> {
        /** Index of the element the next `next()` returns. */
        protected var index = 0

        /** Index the last `next()`/`previous()` returned, or -1. */
        protected var last = -1

        /** The `modCount` this iterator expects the list to still have. */
        protected var expectedModCount = modCount

        override fun hasNext(): Boolean = index < size

        override fun next(): E {
            checkForComodification()
            if (!hasNext()) throw NoSuchElementException()
            last = index++
            return get(last)
        }

        override fun remove() {
            checkForComodification()
            check(last != -1) { "Call next() or previous() before removing element from the iterator." }

            removeAt(last)
            index = last
            last = -1
            expectedModCount = modCount
        }

        protected fun checkForComodification() {
            if (modCount != expectedModCount)
                throw ConcurrentModificationException()
        }
    }

    private inner class ListIteratorImpl(index: Int) : IteratorImpl(), MutableListIterator<E> {

        init {
            AbstractList.checkPositionIndex(index, this@AbstractMutableList.size)
            this.index = index
        }

        override fun hasPrevious(): Boolean = index > 0

        override fun nextIndex(): Int = index

        override fun previous(): E {
            checkForComodification()
            if (!hasPrevious()) throw NoSuchElementException()

            last = --index
            return get(last)
        }

        override fun previousIndex(): Int = index - 1

        override fun add(element: E) {
            checkForComodification()
            add(index, element)
            index++
            last = -1
            expectedModCount = modCount
        }

        override fun set(element: E) {
            checkForComodification()
            check(last != -1) { "Call next() or previous() before updating element value with the iterator." }
            this@AbstractMutableList[last] = element
            expectedModCount = modCount
        }
    }

    private class SubList<E>(private val list: AbstractMutableList<E>, private val fromIndex: Int, toIndex: Int) : AbstractMutableList<E>() {
        private var _size: Int = 0

        init {
            AbstractList.checkRangeIndexes(fromIndex, toIndex, list.size)
            this._size = toIndex - fromIndex
            this.modCount = list.modCount
        }

        override fun add(index: Int, element: E) {
            checkForComodification()
            AbstractList.checkPositionIndex(index, _size)

            list.add(fromIndex + index, element)
            _size++
            modCount = list.modCount
        }

        override fun get(index: Int): E {
            checkForComodification()
            AbstractList.checkElementIndex(index, _size)

            return list[fromIndex + index]
        }

        override fun removeAt(index: Int): E {
            checkForComodification()
            AbstractList.checkElementIndex(index, _size)

            val result = list.removeAt(fromIndex + index)
            _size--
            modCount = list.modCount
            return result
        }

        override fun set(index: Int, element: E): E {
            checkForComodification()
            AbstractList.checkElementIndex(index, _size)

            return list.set(fromIndex + index, element)
        }

        override fun removeRange(fromIndex: Int, toIndex: Int) {
            checkForComodification()
            list.removeRange(this.fromIndex + fromIndex, this.fromIndex + toIndex)
            _size -= toIndex - fromIndex
            modCount = list.modCount
        }

        override val size: Int
            get() {
                checkForComodification()
                return _size
            }

        override fun iterator(): MutableIterator<E> {
            checkForComodification()
            return super.iterator()
        }

        override fun listIterator(index: Int): MutableListIterator<E> {
            checkForComodification()
            return super.listIterator(index)
        }

        private fun checkForComodification() {
            if (list.modCount != modCount)
                throw ConcurrentModificationException()
        }
    }
}
