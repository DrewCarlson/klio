// Named and defaulted constructor arguments, for both primary and
// secondary constructors (reorder, non-trailing omission, all-default).
class Cfg(val name: String = "x", val size: Int = 1, val on: Boolean = false)

class Box(val v: Int) {
    constructor(a: Int = 10, b: Int = 20) : this(a + b)
}

fun main() {
    val a = Cfg(size = 5)
    println("${a.name},${a.size},${a.on}")
    val b = Cfg(on = true, name = "y")
    println("${b.name},${b.size},${b.on}")
    val c = Cfg()
    println("${c.name},${c.size},${c.on}")
    val d = Cfg("z", 9)
    println("${d.name},${d.size},${d.on}")

    println(Box(b = 5).v)
    println(Box(a = 100).v)
    println(Box().v)
    println(Box(1, 2).v)
}
