class Ser<T>(val name: String)

interface Collector {
    fun <T : Any> reg(k: String, s: Ser<T>): Unit = reg(k) { s }
    fun <T : Any> reg(k: String, provider: (List<Ser<*>>) -> Ser<*>)
}

class Builder : Collector {
    val out = mutableListOf<String>()
    override fun <T : Any> reg(k: String, s: Ser<T>) { out.add("argless:$k:${s.name}") }
    override fun <T : Any> reg(k: String, provider: (List<Ser<*>>) -> Ser<*>) { out.add("provider:$k") }
}

fun dump(c: Collector) {
    c.reg("via-iface", Ser<Int>("s"))
}

fun main() {
    val b = Builder()
    b.reg("a", Ser<Int>("s"))
    b.reg("b") { Ser<Int>("t") }
    dump(b)
    println(b.out)
}
