class Sink {
    val out = StringBuilder()
    fun emit(s: String) { out.append(s) }
}

fun go(vararg blocks: Sink.() -> Unit): String {
    val s = Sink(); blocks.forEach { it(s) }; return s.out.toString()
}
fun main() { println(go({ emit("A") }, { emit("B") })) }
