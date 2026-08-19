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

abstract class Base {
    abstract fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R
    fun run(): String {
        val x = B("a"); val y = B("b")
        return x.go(y) { p, q -> "$p$q" }.toString()
    }
}

class VarargUser : Base() {
    override fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R =
        pick(this, other) { args -> f(args[0], args[1]) }
}

class IterableUser : Base() {
    override fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R =
        pick(listOf(this, other)) { args -> f(args[0], args[1]) }
}

fun main() {
    println("VarargUser:");   println("  => " + VarargUser().run())
    println("IterableUser:"); println("  => " + IterableUser().run())
}
