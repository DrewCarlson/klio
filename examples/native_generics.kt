// Generic classes and functions compiled to C. Kotlin erases type arguments, so
// a `T` is a reference like any other: a class parameterised by one lays out
// with a reference field, a function returning one answers a reference, and a
// machine type boxes on the way in. Nothing about the compiled program depends
// on which type was written at the call site.
class Box<T>(val value: T) {
    fun get(): T = value
}

class Pair2<A, B>(val first: A, val second: B) {
    fun swapped(): Pair2<B, A> = Pair2(second, first)
}

fun <T> identity(x: T): T = x

class Stack<T> {
    val items = mutableListOf<T>()
    fun push(x: T) {
        items.add(x)
    }
    fun size(): Int = items.size
}

fun main() {
    println(Box(7).get())
    println(Box("hi").get())

    val p = Pair2(1, "one")
    println(p.first)
    println(p.second)
    println(p.swapped().first)

    println(identity(5))
    println(identity("five"))

    val s = Stack<String>()
    s.push("a")
    s.push("b")
    println(s.size())
}
