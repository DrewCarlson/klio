class Sink {
    val out = StringBuilder()
    fun emit(s: String) { out.append(s) }
}

fun f(vararg blocks: Sink.() -> Unit): String {
    val s = Sink()
    for (b in blocks) b(s)
    return s.out.toString()
}

val b1: Sink.() -> Unit = { emit("A") }
val b2: Sink.() -> Unit = { emit("B") }

fun main() {
    println("0 lit   = " + f())
    println("1 lit   = " + f({ emit("A") }))
    println("2 vars  = " + f(b1, b2))
    println("2 lits  = " + f({ emit("A") }, { emit("B") }))
}
