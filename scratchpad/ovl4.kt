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

fun build(block: Builder.() -> Unit): Builder { val b = Builder(); b.block(); return b }

fun <T : Any> moduleOf(k: String, s: Ser<T>): Builder = build { reg(k, s) }

fun main() {
    val b = Builder()
    b.reg("a", Ser<Int>("s"))
    b.reg("b") { Ser<Int>("t") }
    println(b.out)
    println(moduleOf("c", Ser<Int>("u")).out)
    println(build { reg("d", Ser<Int>("v")) }.out)
}
