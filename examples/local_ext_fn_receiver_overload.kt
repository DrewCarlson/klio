// A bare call inside a body with an implicit receiver resolves against the
// receiver's extensions BEFORE any same-named plain top-level function —
// including inside a LOCAL extension function, whose declared receiver is
// an implicit receiver for its body exactly like a top-level extension's.

class Sink {
    val log = StringBuilder()
}

private fun Sink.emit(s: String) {
    log.append("ext:").append(s).append(" ")
}

private fun emit(s: String) {
    println("plain:" + s)
}

private fun Sink.topLevelExt() {
    emit("top")
}

private fun Sink.withBlock(block: Sink.() -> Unit) = block()

fun main() {
    val sink = Sink()
    sink.topLevelExt()
    sink.withBlock { emit("lambda") }
    fun Sink.localExt() {
        emit("local")
    }
    sink.localExt()
    emit("bare")
    println(sink.log.toString())
}
