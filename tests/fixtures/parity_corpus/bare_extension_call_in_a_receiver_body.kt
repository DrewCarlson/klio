// A bare call in a receiver context resolved MEMBERS of the implicit receiver
// but never its EXTENSIONS, so `toMutableList()` written inside an extension
// body found no target and the local it initializes stayed untyped — and a
// value read out of that local then bound extensions against its RUNTIME
// class. Members are still tried first, exactly as Kotlin orders them.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun Iterable<Base>.pickTag(): String {
    val copy = toMutableList()
    return copy.removeAt(0).tag()
}

fun <T> Iterable<T>.firstCopy(): T {
    val copy = toMutableList()
    return copy.removeAt(0)
}

fun main() {
    println(listOf<Base>(Derived()).pickTag())
    println(listOf<Base>(Derived()).firstCopy().tag())
}
