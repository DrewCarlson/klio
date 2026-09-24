// Kotlin's exceptions are the JVM's: `IllegalStateException` is a type
// alias of `java.lang.IllegalStateException`, and `NoSuchElementException`
// of `java.util`'s, so an instance's class, its `toString` and its
// `::class.qualifiedName` name the JVM class. `toString` names the class as
// `getClass().getName()` does: a nested class after `$`, and
// `java.lang.Throwable` for `Throwable`, whose `qualifiedName` stays
// `kotlin.Throwable`.
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
