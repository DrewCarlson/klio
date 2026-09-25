// A smart cast on a property inherited from a generic supertype narrows the
// type its receiver sees: `actual` on a `StringSubject : Subject<String>` is
// a `String?`, a `String` once it is not null. On a
// `ComparableSubject<T : Comparable<T>>` it is a `T?`, and once not null a
// `T & Any` whose members are its bound's.

open class Subject<out T>(val actual: T?)

class StringSubject(a: String?) : Subject<String>(a) {
    fun inClass(): Int = if (actual != null) actual.length else -1
}

fun StringSubject.len(): Int = if (actual == null) -1 else actual.length

fun StringSubject.lenThis(): Int = if (this.actual == null) -1 else actual.length

class ComparableSubject<T : Comparable<T>>(a: T?) : Subject<T>(a)

fun <T : Comparable<T>> ComparableSubject<T>.greaterThan(other: T?): Boolean {
    requireNotNull(actual)
    requireNotNull(other)
    return actual > other
}

fun <T : Comparable<T>> ComparableSubject<T>.compareWith(other: T): Int {
    if (actual == null) return -2
    return actual.compareTo(other)
}

fun main() {
    println(StringSubject("abc").len())
    println(StringSubject(null).len())
    println(StringSubject("abcd").lenThis())
    println(StringSubject("hello").inClass())
    println(ComparableSubject(2.5f).greaterThan(1.0f))
    println(ComparableSubject(1).greaterThan(3))
    println(ComparableSubject("a").compareWith("b"))
    println(ComparableSubject<String>(null).compareWith("b"))
}
