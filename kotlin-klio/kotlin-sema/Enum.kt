// klio `actual` the sema pipeline uses for the base class of enum classes.
//
// An enum class's constructor passes each entry's name and ordinal on to
// this constructor, so the members are plain Kotlin over them.

package kotlin

public actual abstract class Enum<E : Enum<E>> actual constructor(name: String, ordinal: Int) : Comparable<E> {
    public actual companion object {}

    public actual final val name: String = name
    public actual final val ordinal: Int = ordinal

    public actual final override fun compareTo(other: E): Int = ordinal - other.ordinal
    public actual final override fun equals(other: Any?): Boolean = this === other
    public actual final override fun hashCode(): Int = super.hashCode()
    public actual override fun toString(): String = name
}
