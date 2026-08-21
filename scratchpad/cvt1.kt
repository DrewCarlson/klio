interface Sink { fun emit(v: Int) }
class L(val out: MutableList<Int>) : Sink {
    override fun emit(v: Int) { out.add(v) }
    override fun toString() = "L"
}
class Holder(val block: Sink.() -> Unit)

// The receiver-lambda value reaches the call site as an anon-object CAPTURE,
// with no `this` in scope where it was created.
fun mk(block: Sink.() -> Unit): (Sink) -> Unit {
    val obj = object {
        fun run(s: Sink) { s.block() }
    }
    return { s -> obj.run(s) }
}

fun main() {
    val out = ArrayList<Int>()
    mk { println("  this = " + this); emit(1) }(L(out))
    println("out = " + out)
}
