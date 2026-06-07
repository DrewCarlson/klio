open class Holder(val n: Int)

class Wrap(d: Holder) : Holder by d

fun main() {
    val w = Wrap(Holder(1))
    println(w.n)
}
