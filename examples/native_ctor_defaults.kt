// A constructor parameter with a default compiled to C. The default is the
// CONSTRUCTION's business, not the class's: the field exists either way, and a
// construction that omits the parameter runs the thunk the declaration lowered
// for it — handed the arguments ahead of it, because a later default may read
// an earlier one.
class Conf(val name: String, val size: Int = 4, val on: Boolean = true) {
    fun show(): String = name + ":" + size + ":" + on
}

class Chain(val a: Int = 1, val b: Int = a + 1, val c: Int = a + b)

class Greeting(val who: String = "world") {
    fun text(): String = "hello " + who
}

fun main() {
    println(Conf("x").show())
    println(Conf("y", 9).show())
    println(Conf("z", on = false).show())
    println(Conf("w", 2, false).show())

    val d = Chain()
    println(d.a)
    println(d.b)
    println(d.c)
    val e = Chain(5)
    println(e.b)
    println(e.c)

    println(Greeting().text())
    println(Greeting("klio").text())
}
