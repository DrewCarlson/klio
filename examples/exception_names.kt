// A throwable's `toString` names its class by its Kotlin qualified name:
// `kotlin.IllegalStateException`, a nested class as `demo.Outer.Inner`, and
// `kotlin.Throwable` for `Throwable`. The exceptions Kotlin has no common
// name for, such as an array index out of range, are klio's own, in package
// `klio`, and `catch` finds them by their Kotlin supertypes too.
package demo

class Outer {
    class Inner(msg: String) : Exception(msg)
}

class Plain : RuntimeException()

fun main() {
    println(Throwable("t"))
    println(Throwable()::class.qualifiedName)
    println(Error("e"))
    println(Exception("x")::class.qualifiedName)
    println(Outer.Inner("in"))
    println(Outer.Inner("in")::class.qualifiedName)
    println(Plain())
    println(NoSuchElementException("n"))
    println(ConcurrentModificationException()::class.qualifiedName)
    println(ArithmeticException("a") is RuntimeException)
    println(AssertionError("as"))
    println(UninitializedPropertyAccessException("u"))
    println(NumberFormatException("nf") is IllegalArgumentException)
    try { intArrayOf(1)[5] } catch (e: ArrayIndexOutOfBoundsException) { println(e::class.qualifiedName) }
    try { "abc".toInt() } catch (e: NumberFormatException) { println(e) }
    try { listOf<Int>().first() } catch (e: NoSuchElementException) { println(e::class.qualifiedName) }
    try { val x: Any = "s"; x as Int } catch (e: ClassCastException) { println(e::class.qualifiedName) }
    try { val z = 0; println(1 / z) } catch (e: ArithmeticException) { println(e) }
    try { error("boom") } catch (e: IllegalStateException) { println(e) }
    try { require(false) { "req" } } catch (e: IllegalArgumentException) { println(e) }
}
