interface Strategy<T> { fun name(): String }
interface KSer<T> : Strategy<T>

class Reflective(val tag: String) : KSer<Any?> { override fun name() = tag }

class Collector {
    fun <T : Any> reg(k: String, s: KSer<T>) = println("value:$k:${s.name()}")
    fun <T : Any> reg(k: String, f: (List<KSer<*>>) -> KSer<*>) = println("func:$k")
}

fun main() {
    val c = Collector()
    val s: KSer<Any?> = Reflective("r")
    c.reg("a", s)
    val star: KSer<*> = Reflective("star")
    c.reg("c", star as KSer<Any>)
    c.reg("b") { Reflective("q") }
}
