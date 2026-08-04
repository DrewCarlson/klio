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

@SinceKotlin("1.1")
public actual abstract class AbstractMutableSet<E> protected actual constructor() : AbstractMutableCollection<E>(), MutableSet<E> {

    @IgnorableReturnValue
    actual abstract override fun add(element: E): Boolean

    override fun equals(other: Any?): Boolean {
        if (other === this) return true
        if (other !is Set<*>) return false
        return AbstractSet.setEquals(this, other)
    }

    override fun hashCode(): Int = AbstractSet.unorderedHashCode(this)
}

