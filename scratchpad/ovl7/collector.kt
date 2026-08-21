package demo

class KCls<T>(val n: String)
interface Ser<T> { val name: String }
class SerImpl<T>(override val name: String) : Ser<T>

interface Collector {
    fun <T : Any> reg(k: KCls<T>, s: Ser<T>): Unit = reg(k) { s }
    fun <T : Any> reg(k: KCls<T>, provider: (List<Ser<*>>) -> Ser<*>)
}
