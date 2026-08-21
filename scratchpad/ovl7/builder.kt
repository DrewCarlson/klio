package demo

class Builder : Collector {
    val out = mutableListOf<String>()
    override fun <T : Any> reg(k: KCls<T>, s: Ser<T>) { out.add("argless:${k.n}") }
    override fun <T : Any> reg(k: KCls<T>, provider: (List<Ser<*>>) -> Ser<*>) { out.add("provider:${k.n}") }
}
