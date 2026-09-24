// Indexing a `List` of objects whose runtime class varies per element
// (polymorphic dispatch) and calling an overridden method on each one.
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
