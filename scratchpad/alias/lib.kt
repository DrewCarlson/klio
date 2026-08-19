package mylib

interface Box<out T> { fun get(): T }
class B<T>(val v: T) : Box<T> { override fun get(): T = v }

inline fun <reified T, R> pick(vararg items: Box<T>, crossinline transform: (Array<T>) -> R): R {
    println("  [vararg]")
    @Suppress("UNCHECKED_CAST")
    return transform(Array<Any?>(items.size) { items[it].get() } as Array<T>)
}

inline fun <reified T, R> pick(items: Iterable<Box<T>>, crossinline transform: (Array<T>) -> R): R {
    println("  [iterable]")
    val arr = items.toList().toTypedArray()
    @Suppress("UNCHECKED_CAST")
    return transform(Array<Any?>(arr.size) { arr[it].get() } as Array<T>)
}
