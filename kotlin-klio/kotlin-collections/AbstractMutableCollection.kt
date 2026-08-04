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

public actual abstract class AbstractMutableCollection<E> protected actual constructor(): MutableCollection<E>, AbstractCollection<E>() {

    @IgnorableReturnValue
    actual override public fun addAll(elements: Collection<E>): Boolean {
        var changed = false
        for (v in elements) {
            if (add(v)) changed = true
        }
        return changed
    }

    @IgnorableReturnValue
    actual override fun remove(element: E): Boolean {
        val it = iterator()
        while (it.hasNext()) {
            if (it.next() == element) {
                it.remove()
                return true
            }
        }
        return false
    }

    @IgnorableReturnValue
    actual override public fun removeAll(elements: Collection<E>): Boolean = (this as MutableIterable<E>).removeAll { it in elements }

    @IgnorableReturnValue
    actual override public fun retainAll(elements: Collection<E>): Boolean = (this as MutableIterable<E>).retainAll { it in elements }

    actual override fun clear(): Unit {
        val it = iterator()
        while (it.hasNext()) {
            val _ = it.next()
            it.remove()
        }
    }
}
