class Sink {
    val out = StringBuilder()
    fun emit(s: String) { out.append(s) }
}

fun viaFor(vararg blocks: Sink.() -> Unit): String {
    val s = Sink(); for (x in blocks) x(s); return s.out.toString()
}
fun viaIndex(vararg blocks: Sink.() -> Unit): String {
    val s = Sink(); var i = 0
    while (i < blocks.size) { blocks[i](s); i += 1 }
    return s.out.toString()
}
fun viaTyped(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    for (x in blocks) { val t: Sink.() -> Unit = x; t(s) }
    return s.out.toString()
}
fun viaForEach(vararg blocks: Sink.() -> Unit): String {
    val s = Sink(); blocks.forEach { it(s) }; return s.out.toString()
}

fun main() {
    val lit1: Sink.() -> Unit = { emit("A") }
    val lit2: Sink.() -> Unit = { emit("B") }
    println("for   typedvals = " + viaFor(lit1, lit2))
    println("for   literals  = " + runCatching { viaFor({ emit("A") }, { emit("B") }) }.getOrElse { "ERR" })
    println("index literals  = " + runCatching { viaIndex({ emit("A") }, { emit("B") }) }.getOrElse { "ERR" })
    println("typed literals  = " + runCatching { viaTyped({ emit("A") }, { emit("B") }) }.getOrElse { "ERR" })
    println("each  literals  = " + runCatching { viaForEach({ emit("A") }, { emit("B") }) }.getOrElse { "ERR" })
}
