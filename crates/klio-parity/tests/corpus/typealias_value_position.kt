// A `typealias` resolves to the aliased declaration in value /
// qualifier position: constructor call, companion factory, and
// companion property — not just in type position.
class Real internal constructor(val v: Int) {
    companion object {
        val ORIGIN: Real = Real(0)
        fun of(x: Int): Real = Real(x)
    }
    fun show(): String = "Real($v)"
}
typealias Alias = Real
typealias Alias2 = Alias

fun use(a: Alias): String = a.show()

fun main() {
    println(Alias.of(7).show())
    println(Alias.ORIGIN.show())
    println(Alias2.of(3).show())
    println(use(Real(9)))
}
