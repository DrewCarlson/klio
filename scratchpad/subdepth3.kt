interface Strategy<T> { fun name(): String }
interface KSer<T> : Strategy<T>

class Reflective(val tag: String) : KSer<Any?> { override fun name() = tag }

interface Coll {
    fun <T : Any> reg(k: String, s: KSer<T>): Unit = reg(k) { s }
    fun <T : Any> reg(k: String, f: (List<KSer<*>>) -> KSer<*>)
}

class Collector : Coll {
    override fun <T : Any> reg(k: String, f: (List<KSer<*>>) -> KSer<*>) = println("func:$k")
    override fun <T : Any> reg(k: String, s: KSer<T>) = println("value:$k:${s.name()}")
}

fun feed(c: Coll, s: KSer<*>) { c.reg("via", s as KSer<Any>) }

fun main() {
    val c = Collector()
    feed(c, Reflective("f"))
    val s: KSer<Any?> = Reflective("r")
    c.reg("a", s)
    c.reg("b") { Reflective("q") }
}
