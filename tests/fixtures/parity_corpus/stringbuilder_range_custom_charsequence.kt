// A StringBuilder's range appends and inserts read a CharSequence of the
// program's own through its length and get, as they read a String.
class Seq(private val s: String) : CharSequence {
    var reads = 0
    override val length: Int get() = s.length
    override fun get(index: Int): Char {
        reads++
        return s[index]
    }
    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence =
        Seq(s.substring(startIndex, endIndex))
    override fun toString(): String = s
}

fun main() {
    val hello = Seq("hello")
    val a = StringBuilder()
    a.append(hello, 1, 3)
    println("[$a] reads=${hello.reads}")
    val b = StringBuilder()
    b.append(Seq(""), 0, 0)
    println("[$b]")
    val c = StringBuilder("ab")
    c.insertRange(1, Seq("xyz"), 0, 2)
    println("[$c]")
    val d = StringBuilder()
    d.appendRange(Seq("hello"), 1, 4)
    println("[$d]")
    val e = StringBuilder("!")
    e.append(Seq("tail"))
    println("[$e]")
    try {
        StringBuilder().appendRange(Seq("abc"), 2, 5)
    } catch (ex: IndexOutOfBoundsException) {
        println("out of range")
    }
}
