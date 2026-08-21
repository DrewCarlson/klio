interface I {
    val name: String
    fun describe(): String = "I:" + name
}
class Base(override val name: String) : I {
    override fun describe(): String = "Base:" + name
}
class Plain(override val name: String) : I

fun main() {
    val a: I = Base("a")
    val b: I = Plain("b")
    println("base   = " + a.describe())
    println("plain  = " + b.describe())
    val list: List<I> = listOf(Base("c"), Plain("d"))
    for (e in list) println("elem   = " + e.describe())
}
