class Contents { var n: Int? = null; var s: String? = null }

class Facade(val c: Contents = Contents()) {
    var n: Int? by c::n
    var s: String? by c::s
    var plain: Int? = null
}

fun main() {
    val f = Facade()
    val pn = Facade::n
    val pp = Facade::plain
    pp.set(f, 7); println("plain get = " + pp.get(f))
    pn.set(f, 5)
    println("deleg get = " + pn.get(f))
    println("direct    = " + f.n)
    println("name      = " + pn.name)
    for (p in listOf(Facade::n, Facade::s)) println("  " + p.name + " = " + p.get(f))
}
