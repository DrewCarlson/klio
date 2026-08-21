class Sink {
    val out = StringBuilder()
    fun emit(s: String) { out.append(s) }
}

fun go(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    for (x in blocks) { val t: Sink.() -> Unit = x; t(s) }
    return s.out.toString()
}
fun main() { println(go({ emit("A") }, { emit("B") })) }
