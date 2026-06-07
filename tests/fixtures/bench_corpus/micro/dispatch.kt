open class Hitter { open fun hit(x: Int) = x + 1 }
class Plus2 : Hitter() { override fun hit(x: Int) = x + 2 }
class Plus3 : Hitter() { override fun hit(x: Int) = x + 3 }

fun main() {
    val xs: List<Hitter> = listOf(Plus2(), Plus3(), Hitter())
    var s = 0
    var i = 0
    while (i < 20000) {
        s = xs[i % 3].hit(s)
        i += 1
    }
    println(s)
}
