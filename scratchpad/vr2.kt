class Sink {
    val out = StringBuilder()
    fun emit(s: String) { out.append(s) }
}

// two DECLARED params (args.len == params.len path)
fun g(a: Sink.() -> Unit, b: Sink.() -> Unit): String {
    val s = Sink(); a(s); b(s); return s.out.toString()
}

// vararg
fun f(vararg blocks: Sink.() -> Unit): String {
    val s = Sink(); for (x in blocks) x(s); return s.out.toString()
}

fun main() {
    println("declared 2 = " + g({ emit("A") }, { emit("B") }))
    println("vararg  2  = " + f({ emit("A") }, { emit("B") }))
}
