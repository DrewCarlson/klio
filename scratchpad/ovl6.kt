class KCls<T>(val n: String)
interface Ser<T> { val name: String }
class SerImpl<T>(override val name: String) : Ser<T>

sealed class Provider {
    class Argless(val ser: Ser<*>) : Provider()
    class WithArgs(val f: (List<Ser<*>>) -> Ser<*>) : Provider()
}

interface Collector {
    fun <T : Any> reg(k: KCls<T>, s: Ser<T>): Unit = reg(k) { s }
    fun <T : Any> reg(k: KCls<T>, provider: (List<Ser<*>>) -> Ser<*>)
}

class Builder : Collector {
    val out = mutableListOf<String>()
    override fun <T : Any> reg(k: KCls<T>, s: Ser<T>) { out.add("argless:${k.n}") }
    override fun <T : Any> reg(k: KCls<T>, provider: (List<Ser<*>>) -> Ser<*>) { out.add("provider:${k.n}") }
}

class Module(private val map: Map<KCls<*>, Provider>) {
    fun dumpTo(collector: Collector) {
        map.forEach { (kcls, p) ->
            when (p) {
                is Provider.Argless -> collector.reg(kcls as KCls<Any>, p.ser as Ser<Any>)
                is Provider.WithArgs -> collector.reg(kcls, p.f)
            }
        }
    }
}

fun main() {
    val k = KCls<Int>("A")
    val m = Module(mapOf(k to Provider.Argless(SerImpl<Int>("s"))))
    val b = Builder()
    m.dumpTo(b)
    println(b.out)
}
