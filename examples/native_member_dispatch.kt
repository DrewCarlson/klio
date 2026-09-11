// Member calls compiled to C. A call the lowering left by name resolves to the
// topmost declaration on the receiver's chain at that name and arity, which is
// the same slot a resolved virtual call names: both spellings go through one
// dispatcher, so an override answers either.
interface Shape {
    fun area(): Int
    fun describe(): String
}

open class Rect(val w: Int, val h: Int) : Shape {
    override fun area(): Int = w * h
    override fun describe(): String = "rect " + area()
}

class Square(val side: Int) : Rect(side, side) {
    override fun describe(): String = "square " + area()
}

fun report(s: Shape): String = s.describe()

fun main() {
    // Named arguments reach the constructor in ITS order.
    val named = Rect(h = 3, w = 2)
    println(named.area())
    val r = Rect(2, 3)
    val q = Square(4)
    println(r.area())
    println(q.area())
    println(report(r))
    println(report(q))
    println(r.describe())
}
