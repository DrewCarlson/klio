// A hot loop indexing a list of objects and dispatching a method on each element.
// The element's class varies per iteration (the list is polymorphic), so the
// loop JIT reads the element with a direct subscript into a boxed register and
// dispatches the method dynamically, re-checking the receiver's class each call.
// Output must match with the JIT off (default) or on (KLIO_JIT=1).
open class Hitter { open fun hit(x: Int): Int = x + 1 }
class Plus2 : Hitter() { override fun hit(x: Int): Int = x + 2 }
class Plus3 : Hitter() { override fun hit(x: Int): Int = x + 3 }

fun main() {
    val xs: List<Hitter> = listOf(Plus2(), Plus3(), Hitter())
    var s = 0
    var i = 0
    while (i < 600000) {
        s = (s + xs[i % 3].hit(i)) and 0x7fffffff
        i = i + 1
    }
    println(s)
}
